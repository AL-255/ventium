#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-freerun.sh — M14 FREE-RUN endurance harness (no gdbstub in the loop).
#
# The TB EMULATES int-0x80 directly (obj_dir_emu, --emulate-syscalls), so the
# Ventium RTL executes a linux-user static ELF to COMPLETION at full Verilator
# speed (~45k insn/s) — enabling billion-instruction runs (coremark to results,
# Quake into the demo) that the ~10k insn/s single-step oracle cannot reach.
#
# Oracle: the program's OWN output. We run the SAME binary+args natively under
# qemu-i386 and require the RTL's captured stdout to match — modulo timing-only
# lines (the RTL uses a synthetic monotonic clock, qemu uses the host clock). The
# benchmarks self-validate (coremark CRCs/"Correct operation validated", dhrystone
# final values, linpack residual, whetstone results), so a match on the DATA lines
# is a strong end-to-end correctness statement.
#
#   bash verif/bench/run-freerun.sh <bench> <max_insn> [stdin_str] [-- argv...]
#
# Exit 0 IFF the RTL's non-timing output matches qemu-native's.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$H/build/qemu/build/qemu-i386"
BINDIR="$H/benchmarks/bin"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
# The standard TB has the emulator linked in (inert unless --emulate-syscalls);
# prefer obj_dir, fall back to obj_dir_emu (the build-while-busy alternate).
TB="$REPO/verif/tb/obj_dir/tb_ventium"
[[ -x "$TB" ]] || TB="$REPO/verif/tb/obj_dir_emu/tb_ventium"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"

[[ $# -ge 2 ]] || { echo "usage: $0 <bench> <max_insn> [stdin_str] [-- argv...]"; exit 2; }
BENCH="$1"; N="$2"; shift 2
STDIN_STR="-"; [[ $# -ge 1 && "$1" != "--" ]] && { STDIN_STR="$1"; shift; }
GUEST_ARGS=(); [[ $# -ge 1 && "$1" == "--" ]] && { shift; GUEST_ARGS=("$@"); }
PORT="${FREERUN_PORT:-55000}"

if [[ "$BENCH" == "quake" ]]; then
  ELF="$H/quake/bin/tyr-quake-p5"; TAG="quake"
  [[ ${#GUEST_ARGS[@]} -eq 0 ]] && GUEST_ARGS=(-basedir "$H/quake" -noconinput -nosound -mem 32)
elif [[ -x "$BENCH" ]]; then ELF="$BENCH"; TAG="$(basename "$BENCH")"
elif [[ -x "$BINDIR/$BENCH" ]]; then ELF="$BINDIR/$BENCH"; TAG="$BENCH"
else echo "ERROR: bench '$BENCH' not found"; exit 2; fi
SUF="$(printf '%s ' "${GUEST_ARGS[@]:-}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//' | cut -c1-40)"
[[ -n "$SUF" ]] && TAG="${TAG}__${SUF}"
OUT="$REPO/build/freerun/$TAG"; mkdir -p "$OUT"
IMAGE="$OUT/image.json"; STDINF="$OUT/stdin.bin"
REF="$OUT/qemu.out"; RTLOUT="$OUT/rtl.out"

[[ -x "$TB" ]] || { echo "ERROR: emulator TB not built — run: make -C verif/tb emu"; exit 1; }
printf '%b' "$STDIN_STR" > "$STDINF"; [[ "$STDIN_STR" == "-" ]] && : > "$STDINF"

echo "######################################################################"
echo "# free-run: $TAG  (max_insn=$N)  args=(${GUEST_ARGS[*]:-})"
echo "######################################################################"

# -- 1. initial process image (single-step ONE insn; we only want the image) ---
echo "== 1. capture initial process image (gen_trace --max-insn 1) =="
GA=(--qemu "$QEMU" --syscall-proxy --elf "$ELF" --out /dev/null --image-out "$IMAGE"
    --max-insn 1 --seed 1234 --cpu pentium --port "$PORT" --x87)
[[ ${#GUEST_ARGS[@]} -gt 0 ]] && GA+=(--args "${GUEST_ARGS[@]}")
"$PY" "$GEN" "${GA[@]}" 2>"$OUT/img.log" || { echo "image capture FAILED"; tail "$OUT/img.log"; exit 1; }

# brk_base = page-up(max end of loaded hex regions): a safe heap origin clear of
# the program. (mmap arena + stack live elsewhere; see syscall_emu.cpp.)
BRK="$("$PY" - "$IMAGE" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
end=0
for r in m.get("regions",[]):
    v=int(str(r["vaddr"]),0)
    if v >= 0x40000000:        # skip the stack (high) + vDSO/vvar — heap is LOW
        continue
    ln=len(r["hex"])//2 if "hex" in r else int(r.get("len",0))
    end=max(end,v+ln)
print(hex((end+0xfff)&~0xfff))
PY
)"
echo "   image: $IMAGE   brk_base=$BRK"

# -- 2. qemu-native reference output -------------------------------------------
echo "== 2. qemu-i386 native reference output =="
"$QEMU" -cpu pentium "$ELF" "${GUEST_ARGS[@]}" < "$STDINF" > "$REF" 2>&1 || true
echo "   ref: $(wc -l < "$REF") lines"

# -- 3. RTL free-run (emulate syscalls) ----------------------------------------
echo "== 3. RTL free-run (--emulate-syscalls) =="
# --out /dev/null: free-run discards the per-instruction trace (we grade the
# captured stdout, not the trace) so nothing accumulates on disk/in RAM.
# --max-cycles must exceed max-insn * CPI (~6-7) or the default 1<<24 cap stops
# the run early; give generous headroom (×16) so the guest reaches exit_group.
MAXCYC=$(( N * 16 ))
"$TB" --out /dev/null --quake-image "$IMAGE" --emulate-syscalls \
      --user-stdin "$STDINF" --user-stdout "$RTLOUT" --brk-base "$BRK" \
      --max-insn "$N" --max-cycles "$MAXCYC" --quiesce 100000 --x87 > "$OUT/tb.log" 2>&1
TRC=$?
echo "   rtl exit=$TRC, $(wc -l < "$RTLOUT" 2>/dev/null || echo 0) lines captured"

# -- 4. grade: compare DATA lines (mask timing/throughput-only lines) ----------
echo "== 4. grade: RTL stdout vs qemu-native (timing lines masked) =="
# mask lines whose value is wall-clock/throughput-derived (differ by construction).
# Mask ONLY wall-clock/throughput-derived lines (they differ by construction:
# synthetic clock vs host clock). Keep all DATA lines (CRCs, counts, results).
mask() { sed -E '/[Tt]ime|secs|sec\.|MIPS|MFLOPS|Iterations\/Sec|ticks|Duration|elapsed|Rate|per second|KIPS|CoreMark [0-9]/d'; }
mask < "$REF"    > "$OUT/qemu.masked"
mask < "$RTLOUT" > "$OUT/rtl.masked"
if diff -u "$OUT/qemu.masked" "$OUT/rtl.masked" > "$OUT/diff.txt" 2>&1; then
  echo "FREERUN-OK: $TAG — RTL data-output IDENTICAL to qemu-native (timing masked)"
  echo "----- guest output (RTL) -----"; cat "$RTLOUT"
  exit 0
else
  echo "FREERUN-MISMATCH: $TAG — RTL output differs from qemu (see $OUT/diff.txt)"
  head -40 "$OUT/diff.txt"
  exit 1
fi
