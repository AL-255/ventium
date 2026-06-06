#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# M7.3a phase 1 — rr=replay DETERMINISM verifier (docs/m7-lockstep-spec.md §M7.3).
#
# Re-runs the recorded boot prefix (replay.bin from record.sh) under rr=replay TWICE
# and proves the captured environment-input timeline is byte-identical across the two
# replays:
#   * the delivered-interrupt stream (-d int): vectors + CS:EIP boundaries
#   * the device-read VALUE stream (memory_region_ops_read): every PIO/MMIO read value
#   * the device-WRITE / DMA stream (memory_region_ops_write)
# Byte-identical A==B is the determinism guarantee the consumer relies on: the RTL can
# be fed EXACTLY these device values + interrupts at exactly these boundaries, every
# run. (Under PLAIN -icount this stream DIVERGES at the first RTC read; under
# rr=replay it does not — that is the whole point of record/replay here.)
#
# USAGE
#   bash replay-verify.sh            # uses build/m7/win95/{replay.bin,overlay.qcow2}
#   OUTDIR=/tmp/m7w95 bash replay-verify.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="${QEMU:-$HARNESS/build/qemu/build-sys/qemu-system-i386}"
OUTDIR="${OUTDIR:-$REPO/build/m7/win95}"
RAM_MB="${RAM_MB:-64}"
CPU="${CPU:-pentium}"
# MUST match record.sh's shift (default 4). A fixed shift replays the full prefix
# including interrupts and self-terminates at rrfile EOF; shift=auto freezes early.
ICOUNT_SHIFT="${ICOUNT_SHIFT:-4}"
# Generous wallclock cap; replay consumes the bounded rrfile and stops at its EOF.
REPLAY_CAP="${REPLAY_CAP:-90}"

OVERLAY="$OUTDIR/overlay.qcow2"
REPLAY_BIN="$OUTDIR/replay.bin"

[[ -x "$QEMU" ]]       || { echo "[replay] missing qemu: $QEMU" >&2; exit 1; }
[[ -s "$REPLAY_BIN" ]] || { echo "[replay] missing rrfile $REPLAY_BIN — run record.sh first" >&2; exit 1; }
[[ -f "$OVERLAY" ]]    || { echo "[replay] missing overlay $OVERLAY — run record.sh first" >&2; exit 1; }

# rr=replay reproduces the recorded stream up to the rrfile's last complete
# checkpoint, then FREEZES (icount stops advancing). We poll the combined log and
# SIGINT once it stops growing, so each replay captures the SAME full prefix.
run_replay() {
  local tag="$1"
  local log="$OUTDIR/replay-$tag.log"          # combined int + devio (one -D channel)
  : > "$log"
  "$QEMU" \
    -machine pc -cpu "$CPU" -m "$RAM_MB" \
    -icount "shift=$ICOUNT_SHIFT,rr=replay,rrfile=$REPLAY_BIN" \
    -drive driver=blkreplay,id=dr0,if=none,image.driver=qcow2,image.file.filename="$OVERLAY" \
    -device ide-hd,drive=dr0,bus=ide.0 \
    -rtc base=utc,clock=vm -net none -display none -no-reboot \
    -d int,trace:memory_region_ops_read,trace:memory_region_ops_write -D "$log" \
    >/dev/null 2>"$OUTDIR/replay-$tag.stderr" &
  local pid=$!
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  # A fixed-shift replay self-terminates at rrfile EOF; just wait for it (cap-bounded).
  # Fallback: if it stalls (shift=auto freeze), SIGINT after the log is stable for 8s.
  local prev=-1 stable=0 waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < REPLAY_CAP )); do
    sleep 1; waited=$((waited+1))
    local cur; cur=$(wc -l < "$log" 2>/dev/null || echo 0)
    if (( cur == prev )); then stable=$((stable+1)); else stable=0; fi
    prev=$cur
    (( stable >= 8 && cur > 0 )) && break
  done
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 8); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$log"
}

# Canonicalize a replay log for comparison: drop the non-deterministic host-side
# MemoryRegion pointer ('mr 0x....') — it varies per QEMU process launch and is NOT
# part of the device contract (addr/value/size/name are). Everything else is graded.
canon() { sed -E 's/ mr 0x[0-9a-fA-F]+ / mr PTR /' "$1"; }

echo "[replay] rrfile : $REPLAY_BIN ($(stat -c %s "$REPLAY_BIN") bytes)"
echo "[replay] === REPLAY A ==="
A_LOG="$(run_replay A)"
echo "[replay]   hwint=$(grep -ac 'Servicing hardware INT' "$A_LOG")  dev-read=$(grep -ac memory_region_ops_read "$A_LOG")  dev-write=$(grep -ac memory_region_ops_write "$A_LOG")"
echo "[replay] === REPLAY B ==="
B_LOG="$(run_replay B)"
echo "[replay]   hwint=$(grep -ac 'Servicing hardware INT' "$B_LOG")  dev-read=$(grep -ac memory_region_ops_read "$B_LOG")  dev-write=$(grep -ac memory_region_ops_write "$B_LOG")"

echo "[replay] === DETERMINISM CHECK (A vs B, host mr-pointer canonicalized) ==="
status=0
# Whole-stream check (interrupts + device reads + device writes, in order).
ha=$(canon "$A_LOG" | sha256sum | cut -d' ' -f1)
hb=$(canon "$B_LOG" | sha256sum | cut -d' ' -f1)
if [[ "$ha" == "$hb" ]]; then
  echo "[replay]   full env-input stream : IDENTICAL ($ha)"
else
  echo "[replay]   full env-input stream : DIVERGENT"; diff <(canon "$A_LOG") <(canon "$B_LOG") | head; status=1
fi
# Per-class checks for a clearer signal.
for kind in 'Servicing hardware INT' 'memory_region_ops_read' 'memory_region_ops_write'; do
  na=$(grep -ac "$kind" "$A_LOG" || true)
  ka=$( { canon "$A_LOG" | grep -a "$kind" || true; } | sha256sum | cut -d' ' -f1)
  kb=$( { canon "$B_LOG" | grep -a "$kind" || true; } | sha256sum | cut -d' ' -f1)
  if [[ "$ka" == "$kb" ]]; then
    echo "[replay]   [$kind]: IDENTICAL ($na records)"
  else
    echo "[replay]   [$kind]: DIVERGENT"; status=1
  fi
done

echo
if [[ "$status" == 0 ]]; then
  echo "WIN95-REPLAY-DETERMINISTIC: two rr=replay runs are byte-identical"
  echo "  (interrupts + device-read values + device writes reproduce bit-for-bit — the"
  echo "   consumer can inject exactly this timeline into the RTL every run)."
else
  echo "WIN95-REPLAY-DIVERGENT: replays differ — investigate before building the consumer"
fi
exit $status
