#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-deep-lockstep.sh — DEEP per-instruction differential lock-step, O(1) disk.
#
# Same rigorous M7.1 recipe as run-bench-lockstep.sh (QEMU gdbstub golden =
# environment, RTL = checked CPU, int-0x80 proxy replays kernel effects,
# compare.py grades EVERY retired instruction's full arch+x87 state) — but built
# to run MUCH deeper than the 59 GB free disk allows:
#
#   * the golden + RTL traces are written through zstd (a ~8-12x squeeze on the
#     repetitive JSON), and
#   * both compressed traces are DELETED the instant the verdict is in,
#
# so peak disk is ~(depth * 718 B / ratio) per in-flight config, not the raw
# 718 B/insn. The verdict + first-divergence context (the only thing we keep) go
# to <out>/verdict.txt. Run programs to COMPLETION when the chosen workload fits
# under --max-insn (then every instruction entry->exit is graded), else grade the
# longest prefix the budget allows.
#
#   bash verif/bench/run-deep-lockstep.sh <bench> <max_insn> <port> [stdin_str] [-- argv...]
#     <bench>      name under benchmarks/bin, OR 'quake', OR an absolute ELF path.
#     <max_insn>   prefix cap (program may exit earlier; then it is fully graded).
#     <port>       gdbstub port (unique per concurrent run).
#     stdin_str    bytes to feed the guest on stdin ('-' = none; e.g. '100\nq\n').
#     -- argv...   guest argv (e.g. -- nqueens 12 ; -- 0x0 0x0 0x66 80).
#
# Exit 0 IFF the graded run is EQUIVALENT (RTL == QEMU). Non-zero => divergence
# (first-divergence record saved) OR a producer/proxy error (logged).
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$H/build/qemu/build/qemu-i386"
BINDIR="$H/benchmarks/bin"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
# STREAMING comparator (compare_stream.py reads line-by-line, ~constant memory).
# compare.py --all loads ALL records of BOTH traces into RAM (millions of dicts),
# which OOMs at depth — never use it for deep runs.
CMP="$REPO/verif/diff/compare_stream.py"
TB="${TB_OVERRIDE:-$REPO/verif/tb/obj_dir/tb_ventium}"   # TB_OVERRIDE for debug builds
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"
ZSTD="$(command -v zstd)"; : "${ZSTD:?need zstd}"

[[ $# -ge 3 ]] || { echo "usage: $0 <bench> <max_insn> <port> [stdin_str] [-- argv...]"; exit 2; }
BENCH="$1"; N="$2"; PORT="$3"; shift 3
STDIN_STR="-"
[[ $# -ge 1 && "$1" != "--" ]] && { STDIN_STR="$1"; shift; }
GUEST_ARGS=()
[[ $# -ge 1 && "$1" == "--" ]] && { shift; GUEST_ARGS=("$@"); }

# Resolve <bench>.
if [[ "$BENCH" == "quake" ]]; then
  ELF="$H/quake/bin/tyr-quake-p5"; TAG="quake"
  # Quake needs its data dir + headless flags (mirrors run-quake-lockstep.sh).
  [[ ${#GUEST_ARGS[@]} -eq 0 ]] && GUEST_ARGS=(-basedir "$H/quake" -noconinput -nosound -mem 32)
elif [[ -x "$BENCH" ]]; then ELF="$BENCH"; TAG="$(basename "$BENCH")"
elif [[ -x "$BINDIR/$BENCH" ]]; then ELF="$BINDIR/$BENCH"; TAG="$BENCH"
else echo "ERROR: bench '$BENCH' not found"; exit 2; fi

SUF="$(printf '%s ' "${GUEST_ARGS[@]:-}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//' | cut -c1-40)"
[[ -n "$SUF" ]] && TAG="${TAG}__${SUF}"
OUT="$REPO/build/deep/$TAG"; mkdir -p "$OUT"
GZ="$OUT/golden.vtrace.zst"; RZ="$OUT/rtl.vtrace.zst"
SC="$OUT/syscalls.txt"   # tiny SEEKABLE syscall sidecar for the TB (see below)
IMAGE="$OUT/image.json"; VERD="$OUT/verdict.txt"
PRODLOG="$OUT/producer.log"; TBLOG="$OUT/tb.log"; CMPLOG="$OUT/compare.log"

[[ -x "$QEMU" && -x "$ELF" ]] || { echo "missing qemu/elf"; exit 1; }

say(){ printf '[deep:%s] %s\n' "$TAG" "$*"; }
say "ELF=$ELF  N=$N  port=$PORT  args=(${GUEST_ARGS[*]:-})  stdin=${STDIN_STR}"

# -- 1. producer: golden -> zstd (compressed on disk), + initial image ---------
say "producer: single-step golden (--x87), streaming through zstd"
GEN_ARGS=(--qemu "$QEMU" --syscall-proxy --elf "$ELF" --out /dev/stdout
          --image-out "$IMAGE" --max-insn "$N" --seed 1234 --cpu pentium
          --port "$PORT" --x87)
[[ ${#GUEST_ARGS[@]} -gt 0 ]] && GEN_ARGS+=(--args "${GUEST_ARGS[@]}")
if [[ "$STDIN_STR" == "-" ]]; then
  "$PY" "$GEN" "${GEN_ARGS[@]}" 2>"$PRODLOG" | "$ZSTD" -q -T4 -3 -o "$GZ" -f
else
  printf '%b' "$STDIN_STR" | "$PY" "$GEN" "${GEN_ARGS[@]}" 2>"$PRODLOG" | "$ZSTD" -q -T4 -3 -o "$GZ" -f
fi
PRC=${PIPESTATUS[0]}
[[ "$PRC" == 0 ]] || { say "PRODUCER FAILED (rc=$PRC)"; tail -5 "$PRODLOG" | sed 's/^/   /'; echo "PRODUCER-FAIL rc=$PRC" >"$VERD"; rm -f "$GZ"; exit 1; }
GRECS=$("$ZSTD" -dc "$GZ" | wc -l)
say "golden: $GRECS records ($(du -h "$GZ" | cut -f1) compressed)"

# tb's load_syscall_replay slurps its --lockstep file via fseek (0 bytes on a
# pipe), so it CANNOT read the golden from a zstd FIFO. The replay only needs the
# int-0x80 records + each one's FOLLOWING record (whose pc is the resume_eip). So
# extract just those into a tiny SEEKABLE sidecar (keep line 1 = the header the
# parser skips). compare.py, by contrast, streams fine straight from the FIFO.
"$ZSTD" -dc "$GZ" | awk '
  NR==1 { print; next }
  {
    pr=0
    if (wn) { print; wn=0; pr=1 }              # the resume-record for a pending syscall
    if ($0 ~ /"sys_call":\{/) { if(!pr) print; wn=1 }
  }' > "$SC"
say "syscall sidecar: $(grep -c '"sys_call":{' "$SC") int-0x80 records ($(wc -l <"$SC") lines)"

# -- 2. RTL lock-step: syscalls from the seekable sidecar, RTL trace -> zstd ----
say "RTL lock-step (proxy replays kernel effects); RTL trace -> zstd"
"$TB" --quake-image "$IMAGE" --lockstep "$SC" \
      --out >("$ZSTD" -q -T4 -3 -o "$RZ" -f) --max-insn "$N" --x87 >"$TBLOG" 2>&1
TRC=$?
sync
[[ "$TRC" == 0 ]] || { say "RTL TB FAILED (rc=$TRC)"; tail -5 "$TBLOG" | sed 's/^/   /'; echo "TB-FAIL rc=$TRC" >"$VERD"; rm -f "$GZ" "$RZ"; exit 1; }
say "rtl trace written (compressed)"

# -- 3. grade: STREAMING compare (compare_stream.py, ~constant memory) ----------
say "grade: compare_stream.py --x87 (streaming; low memory)"
set +e
"$PY" "$CMP" <("$ZSTD" -dc "$GZ") <("$ZSTD" -dc "$RZ") --x87 >"$CMPLOG" 2>&1
RC=$?
set -e
{ echo "=== deep verdict: $TAG ==="; echo "elf=$ELF  N=$N  args=(${GUEST_ARGS[*]:-})  stdin=${STDIN_STR}";
  echo "golden_records=$GRECS"; echo "compare_rc=$RC"; echo "---"; cat "$CMPLOG"; } >"$VERD"

# -- 4. reclaim disk: keep only verdict.txt + image ----------------------------
rm -f "$GZ" "$RZ" "$SC"

if [[ "$RC" == 0 ]]; then
  say "DEEP-LOCKSTEP-OK: $GRECS-insn run EQUIVALENT (RTL bit-exact vs QEMU)"
else
  say "DEEP-LOCKSTEP-DIVERGENT: first-divergence in $VERD"
  grep -nE 'DIVERGE|mismatch|first|n=|FAIL|differs' "$CMPLOG" | head -8 | sed 's/^/   /'
fi
exit $RC
