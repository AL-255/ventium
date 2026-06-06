#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# M7.3a phase 1 — Win95 RECORD/REPLAY producer (docs/m7-lockstep-spec.md §M7.3).
#
# WHAT THIS IS
#   The PRODUCER half of the Win95 input-replay lock-step. It boots Windows 95 on
#   qemu-system-i386 8.2.2 under QEMU record/replay and emits a DETERMINISTIC,
#   re-runnable BOOT PREFIX plus the captured environment-input timeline that the
#   next-phase co-sim-bus CONSUMER will inject into the Ventium RTL:
#     * replay.bin   — the rr=record event log: the authoritative, byte-identical
#                      replayable timeline (the "golden environment").
#     * record-int.log    — every delivered interrupt/exception (-d int): vector +
#                           CS:EIP boundary + errcode (the `intr` contract field).
#     * record-devio.log  — every PIO/MMIO device READ value the CPU consumed and
#                           every device WRITE/DMA the CPU emitted, via the generic
#                           memory_region_ops_{read,write} trace events (the `dev_in`
#                           contract + the DMA/MMIO-write stream).
#
# WHY RECORD/REPLAY (and NOT plain -icount)
#   M7.0 de-risk proved: a Win95 boot under PLAIN -icount DIVERGES run-to-run at the
#   very first RTC read (CMOS 0x70/0x71) — the device timeline is not reproducible.
#   Under rr=record→rr=replay the ENTIRE device + interrupt timeline is captured into
#   replay.bin and is bit-identical on every replay (verified by replay-verify.sh:
#   two replays produce byte-identical int + device-read streams). That determinism
#   is the precondition for grading the RTL: the consumer can inject EXACTLY the
#   values QEMU's devices produced, at exactly the same boundaries, every time.
#
# READ-ONLY DISCIPLINE
#   ventium-refs/ is a read-only submodule. This script NEVER writes there: it makes
#   a qcow2 COW OVERLAY of the read-only base win95.qcow2 (under build/m7/ or $TMPDIR)
#   and drives that overlay through QEMU's blkreplay block layer so disk I/O is part
#   of the recorded timeline too. The base qcow2 is never modified.
#
# BOUNDED (NEVER a full boot)
#   A full Win95 boot is ~1e9 insns — wall-clock-prohibitive here and far past the
#   RTL's coverage. This records only a SHORT deterministic boot PREFIX: BIOS POST
#   -> bootloader -> the real-mode/PM/paging transitions. The bound is a wallclock
#   budget (RECORD_SECONDS, default 8s) after which QEMU is sent a clean shutdown so
#   the rrfile is finalized. Report honestly where the prefix reaches (see the
#   summary this script prints + replay-verify.sh).
#
# USAGE
#   bash record.sh                       # default 8s prefix, artifacts in build/m7/win95/
#   RECORD_SECONDS=12 bash record.sh     # longer prefix
#   OUTDIR=/tmp/m7w95 bash record.sh     # different artifact dir
#   Then: bash replay-verify.sh          # proves rr=replay determinism (2x byte-identical)
set -euo pipefail

# --- paths (all absolute; ventium-refs is read-only) ------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="${QEMU:-$HARNESS/build/qemu/build-sys/qemu-system-i386}"
QEMU_IMG="${QEMU_IMG:-$(command -v qemu-img || true)}"
BASE_DISK="${BASE_DISK:-$HARNESS/win95/win95.qcow2}"      # READ-ONLY base C: drive
OUTDIR="${OUTDIR:-$REPO/build/m7/win95}"                  # all writable artifacts here

# --- knobs ------------------------------------------------------------------
RECORD_SECONDS="${RECORD_SECONDS:-8}"   # wallclock budget for the recorded prefix
RAM_MB="${RAM_MB:-64}"                  # Win95-era memory (lib.sh default)
CPU="${CPU:-pentium}"                   # the P5 under harness
# ICOUNT shift: rr=record writes the full nondeterministic-input timeline into rrfile.
# We use a FIXED shift (lib.sh's deterministic 62 MHz Pentium clock, shift=4) — NOT
# shift=auto. EMPIRICAL REASON (verified here): under shift=auto, rr=replay FREEZES at
# the first periodic-timer boundary (icount stops advancing right before the first
# delivered IRQ0) because auto's wallclock-coupled clock-warp events do not replay
# cleanly — so the interrupt timeline is unreachable on replay. Under a FIXED shift the
# virtual clock is fully decoupled from wallclock; rr=replay reproduces the ENTIRE
# recorded prefix INCLUDING every delivered interrupt and then self-terminates cleanly
# at rrfile EOF. (Override with ICOUNT_SHIFT=auto to reproduce the freeze.)
ICOUNT_SHIFT="${ICOUNT_SHIFT:-4}"

# --- preflight --------------------------------------------------------------
[[ -x "$QEMU" ]]      || { echo "[record] missing qemu-system-i386: $QEMU" >&2; exit 1; }
[[ -n "$QEMU_IMG" ]]  || { echo "[record] missing qemu-img on PATH" >&2; exit 1; }
[[ -f "$BASE_DISK" ]] || { echo "[record] missing base disk: $BASE_DISK" >&2; exit 1; }

mkdir -p "$OUTDIR"
OVERLAY="$OUTDIR/overlay.qcow2"         # COW overlay over the read-only base
REPLAY_BIN="$OUTDIR/replay.bin"         # the rr=record event log (the golden timeline)
INT_LOG="$OUTDIR/record-int.log"        # delivered interrupts/exceptions (-d int)
DEVIO_LOG="$OUTDIR/record-devio.log"    # PIO/MMIO read VALUES + writes (DMA) trace
META="$OUTDIR/record-meta.txt"          # provenance + the bounded-prefix summary

echo "[record] repo            : $REPO"
echo "[record] qemu            : $QEMU"
echo "[record] base disk (RO)  : $BASE_DISK"
echo "[record] outdir          : $OUTDIR"
echo "[record] record seconds  : $RECORD_SECONDS"

# --- 1. COW overlay over the read-only base (base never touched) ------------
rm -f "$OVERLAY"
"$QEMU_IMG" create -f qcow2 -b "$BASE_DISK" -F qcow2 "$OVERLAY" >/dev/null
echo "[record] overlay         : $OVERLAY  (backing: $BASE_DISK)"

# --- 2. RECORD: boot Win95 under rr=record + blkreplay, bounded -------------
# Block I/O goes through driver=blkreplay so disk completions are part of the
# recorded timeline (required for deterministic replay). -rtc base=utc,clock=vm
# REPLACES lib.sh's `-rtc base=localtime` (localtime makes the RTC wallclock-
# dependent and breaks replay). -net none / -display none keep it headless +
# free of nondeterministic external inputs. -no-reboot so a triple-fault exits.
rm -f "$INT_LOG" "$DEVIO_LOG" "$REPLAY_BIN"

QEMU_ARGS=(
  -machine pc                                  # i440FX (Win95 chokes on q35)
  -cpu "$CPU"
  -m "$RAM_MB"
  -icount "shift=$ICOUNT_SHIFT,rr=record,rrfile=$REPLAY_BIN"
  -drive driver=blkreplay,id=dr0,if=none,image.driver=qcow2,image.file.filename="$OVERLAY"
  -device ide-hd,drive=dr0,bus=ide.0
  -rtc base=utc,clock=vm                       # deterministic clock (NOT localtime)
  # NB: NO `-boot order=...` — the single IDE disk is the only boot device, and an
  # explicit -boot order makes the recorded boot-select timeline non-replayable here
  # (empirically the rrfile then reproduces 0 device events). Default boot is correct.
  -net none
  -display none
  -no-reboot
  -d int                                       # delivered interrupts/exceptions
  -D "$INT_LOG"
  -name "Win95 M7.3a record"
)

echo "[record] starting record for ${RECORD_SECONDS}s ..."
"$QEMU" "${QEMU_ARGS[@]}" >/dev/null 2>"$OUTDIR/record.stderr" &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

# Bound the prefix by wallclock, then SIGTERM QEMU and give it a fixed FLUSH GRACE so
# the rrfile is finalized cleanly. EMPIRICAL (verified here): killing QEMU before it
# finishes flushing yields a TRUNCATED rrfile whose replay reproduces 0 events — the
# grace period is load-bearing. (QMP `quit` aborts the recording: shorter/unusable.)
FLUSH_GRACE="${FLUSH_GRACE:-4}"
end=$(( $(date +%s) + RECORD_SECONDS ))
while [[ $(date +%s) -lt $end ]] && kill -0 "$QPID" 2>/dev/null; do sleep 0.25; done
kill -TERM "$QPID" 2>/dev/null || true
sleep "$FLUSH_GRACE"                       # let QEMU finalize the rrfile (do NOT race)
kill -9 "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
trap - EXIT

[[ -s "$REPLAY_BIN" ]] || { echo "[record] FAILED: empty rrfile $REPLAY_BIN"; cat "$OUTDIR/record.stderr"; exit 1; }

# --- 3. capture the device-read VALUES on a DETERMINISTIC replay -------------
# The memory_region_ops_{read,write} trace events share QEMU's single -D log with
# -d int, so we capture the high-volume device-I/O stream on a SEPARATE pass: a
# rr=replay of the rrfile just recorded. Replay reproduces the recorded device
# timeline bit-for-bit (proven by replay-verify.sh), so this DEVIO_LOG is the exact
# device-read VALUE stream the recorded prefix consumed — just routed to its own
# file. (`-d trace:` routes trace events to -D as human-readable lines.)
#
# With a FIXED shift, rr=replay reproduces the ENTIRE recorded prefix and then SELF-
# TERMINATES at rrfile EOF. So we let it run to natural exit, only guarding with a
# generous wallclock cap (no premature freeze-kill — that was a shift=auto workaround).
echo "[record] capturing device-I/O VALUES on a deterministic replay pass ..."
: > "$DEVIO_LOG"
"$QEMU" \
  -machine pc -cpu "$CPU" -m "$RAM_MB" \
  -icount "shift=$ICOUNT_SHIFT,rr=replay,rrfile=$REPLAY_BIN" \
  -drive driver=blkreplay,id=dr0,if=none,image.driver=qcow2,image.file.filename="$OVERLAY" \
  -device ide-hd,drive=dr0,bus=ide.0 \
  -rtc base=utc,clock=vm -net none -display none -no-reboot \
  -d trace:memory_region_ops_read,trace:memory_region_ops_write -D "$DEVIO_LOG" \
  >/dev/null 2>"$OUTDIR/record-devio.stderr" &
RPID=$!
trap 'kill "$RPID" 2>/dev/null || true' EXIT
cap=$(( RECORD_SECONDS * 12 + 60 )); waited=0
# Wait for clean self-exit at EOF; if it stalls (e.g. ICOUNT_SHIFT=auto override),
# fall back to the freeze heuristic: SIGINT once the log has been stable for 8s.
prev=-1; stable=0
while kill -0 "$RPID" 2>/dev/null && (( waited < cap )); do
  sleep 1; waited=$((waited+1))
  cur=$(wc -l < "$DEVIO_LOG" 2>/dev/null || echo 0)
  if (( cur == prev )); then stable=$((stable+1)); else stable=0; fi
  prev=$cur
  (( stable >= 8 && cur > 0 )) && { echo "[record] (replay log stalled — likely shift=auto freeze; stopping)"; break; }
done
kill -INT "$RPID" 2>/dev/null || true
for _ in $(seq 1 8); do kill -0 "$RPID" 2>/dev/null || break; sleep 0.25; done
kill -9 "$RPID" 2>/dev/null || true
wait "$RPID" 2>/dev/null || true
trap - EXIT
[[ -s "$DEVIO_LOG" ]] || echo "[record] WARN: empty device-I/O log $DEVIO_LOG"

# --- 4. summarize the captured prefix ---------------------------------------

rr_bytes=$(stat -c %s "$REPLAY_BIN")
int_lines=$(wc -l < "$INT_LOG" 2>/dev/null || echo 0)
# delivered hardware interrupts vs CPU exceptions/faults, plus the first IRQ vector
hw_int=$(grep -ac 'Servicing hardware INT' "$INT_LOG" 2>/dev/null || echo 0)
first_vec=$(grep -am1 -E 'Servicing hardware INT=0x|^ *v=' "$INT_LOG" 2>/dev/null || echo '(none)')
dev_reads=$(grep -ac 'memory_region_ops_read' "$DEVIO_LOG" 2>/dev/null || echo 0)
dev_writes=$(grep -ac 'memory_region_ops_write' "$DEVIO_LOG" 2>/dev/null || echo 0)
first_eip=$(grep -am1 -E 'EIP=' "$INT_LOG" 2>/dev/null | sed -E 's/.*(EIP=[0-9a-fA-F]+).*/\1/' || echo '(none)')

{
  echo "# M7.3a Win95 record provenance"
  echo "date              : $(date -u +%FT%TZ)"
  echo "qemu              : $($QEMU --version | head -1)"
  echo "base_disk_ro      : $BASE_DISK"
  echo "base_disk_sha     : $(sha256sum "$BASE_DISK" | cut -d' ' -f1)"
  echo "overlay           : $OVERLAY"
  echo "record_seconds    : $RECORD_SECONDS"
  echo "icount            : shift=$ICOUNT_SHIFT,rr=record"
  echo "replay_bin        : $REPLAY_BIN ($rr_bytes bytes)"
  echo "replay_bin_sha    : $(sha256sum "$REPLAY_BIN" | cut -d' ' -f1)"
  echo "int_log_lines     : $int_lines"
  echo "hw_interrupts     : $hw_int"
  echo "first_int_eip     : $first_eip"
  echo "first_irq_record  : $first_vec"
  echo "dev_reads         : $dev_reads   (memory_region_ops_read = dev_in values)"
  echo "dev_writes        : $dev_writes  (memory_region_ops_write = DMA/MMIO writes)"
} | tee "$META"

echo
echo "[record] DONE. Bounded boot prefix captured."
echo "[record]   rrfile (golden timeline) : $REPLAY_BIN"
echo "[record]   interrupts (intr)        : $INT_LOG"
echo "[record]   device I/O (dev_in/DMA)  : $DEVIO_LOG"
echo "[record]   provenance               : $META"
echo "[record] Next: bash $(dirname "${BASH_SOURCE[0]}")/replay-verify.sh   (proves rr=replay determinism)"
