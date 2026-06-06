#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-bench-lockstep.sh — Ventium STANDARD-BENCHMARK differential lock-step.
#
# Runs an arbitrary linux-user *static* i386 ELF (the EEMBC/classic benchmark
# corpus prebuilt in ventium-refs: coremark, whetstone, stream, microbench,
# kernels, ...) on the Ventium RTL in lock-step against qemu-i386 8.2.2, EXACTLY
# the M7.1 Quake recipe but for an arbitrary guest:
#
#   QEMU (gdbstub, single-step) = the golden + environment; the RTL = the CHECKED
#   CPU; the int-0x80 proxy replays kernel syscall effects (eax + kernel memory
#   writes + the %gs TLS base) so the RTL never executes the kernel; compare.py
#   grades ONLY the CPU architectural delta (GPRs/EIP/EFLAGS + FULL x87 state via
#   --x87). A divergence on a normal instruction = a real Ventium CPU bug.
#
# These guests exercise code paths the directed corpus never touches: real libc
# (memcpy/memset/printf/malloc), long FP chains (whetstone/linpack/matmul_fp),
# CRC/list/state-machine integer work (coremark), and big strided memory loops
# (stream). That breadth is the point — it is the richest bug surface we have.
#
#   bash verif/bench/run-bench-lockstep.sh <bench> [N_INSNS] [PORT] [-- <argv...>]
#
#     <bench>    a name under benchmarks/bin (coremark|whetstone|stream|microbench|
#                kernels|dhrystone|linpack) OR an absolute path to a static i386 ELF.
#     N_INSNS    retired-instruction prefix to grade (default 200000). The gdbstub
#                oracle is the throughput bound (~10k insn/s), so we grade the
#                longest prefix you budget for and report bit-exactness + the first
#                divergence — not a full run to completion.
#     PORT       gdbstub port (default 53000).
#     -- argv... everything after `--` is forwarded to the guest (e.g. for
#                `kernels`: -- nqueens 8 ; for `microbench`: -- alu 100000).
#
# Exit 0 IFF the graded prefix is byte-exact EQUIVALENT (RTL == QEMU). Non-zero =>
# a divergence (the first-divergence record is printed = a CPU bug unless it is a
# documented harness/proxy limitation — an unmodeled syscall or host-id nondeterminism).
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$HARNESS/build/qemu/build/qemu-i386"
BINDIR="$HARNESS/benchmarks/bin"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
CMP="$REPO/verif/diff/compare.py"
TB="$REPO/verif/tb/obj_dir/tb_ventium"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"

[[ $# -ge 1 ]] || { echo "usage: $0 <bench> [N_INSNS] [PORT] [-- <argv...>]"; exit 2; }

BENCH="$1"; shift
N="200000"; PORT="53000"
GUEST_ARGS=()
# positional N_INSNS / PORT, then optional `-- argv...`
[[ $# -ge 1 && "$1" != "--" ]] && { N="$1"; shift; }
[[ $# -ge 1 && "$1" != "--" ]] && { PORT="$1"; shift; }
if [[ $# -ge 1 && "$1" == "--" ]]; then shift; GUEST_ARGS=("$@"); fi

# Resolve <bench> to an ELF path.
if [[ -x "$BENCH" ]]; then ELF="$BENCH"; TAG="$(basename "$BENCH")"
elif [[ -x "$BINDIR/$BENCH" ]]; then ELF="$BINDIR/$BENCH"; TAG="$BENCH"
else echo "ERROR: benchmark '$BENCH' not found (looked in $BINDIR and as a path)"; exit 2; fi

# A per-(bench,args) tag so concurrent/repeat runs don't collide.
SUF="$(printf '%s ' "${GUEST_ARGS[@]:-}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
[[ -n "$SUF" ]] && TAG="${TAG}__${SUF}"
OUT="$REPO/build/bench/$TAG"; mkdir -p "$OUT"
GOLDEN="$OUT/golden.vtrace"; IMAGE="$OUT/image.json"; RTL="$OUT/rtl.vtrace"

[[ -x "$QEMU" ]] || { echo "missing oracle qemu-i386: $QEMU"; exit 1; }
[[ -x "$ELF"  ]] || { echo "missing guest ELF: $ELF"; exit 1; }

echo "######################################################################"
echo "# bench-lockstep: $TAG   (N=$N insns, port=$PORT)"
echo "#   ELF : $ELF"
echo "#   args: ${GUEST_ARGS[*]:-(none)}"
echo "######################################################################"

echo "== 1. producer: golden + initial process image (single-step, --x87) =="
GEN_ARGS=(--qemu "$QEMU" --syscall-proxy --elf "$ELF"
          --out "$GOLDEN" --image-out "$IMAGE"
          --max-insn "$N" --seed 1234 --cpu pentium --port "$PORT" --x87)
[[ ${#GUEST_ARGS[@]} -gt 0 ]] && GEN_ARGS+=(--args "${GUEST_ARGS[@]}")
"$PY" "$GEN" "${GEN_ARGS[@]}" || { echo "PRODUCER FAILED (see above)"; exit 1; }
echo "   golden: $(wc -l < "$GOLDEN") records ; image: $IMAGE"

echo "== 2. build the RTL TB (verif/tb) =="
# BENCH_SKIP_BUILD=1 lets a parallel sweep build the TB ONCE up front and then
# run many configs concurrently without racing on the shared obj_dir.
if [[ "${BENCH_SKIP_BUILD:-0}" == "1" ]]; then
  [[ -x "$TB" ]] || { echo "BENCH_SKIP_BUILD=1 but TB not built: $TB"; exit 1; }
  echo "   (skipped — using prebuilt $TB)"
else
  make -C "$REPO/verif/tb" rtl >/dev/null || { echo "RTL build failed"; exit 1; }
fi

echo "== 3. RTL lock-step (checked CPU; int-0x80 proxy replays kernel effects) =="
"$TB" --quake-image "$IMAGE" --lockstep "$GOLDEN" --out "$RTL" --max-insn "$N" --x87 \
    || { echo "RTL TB run FAILED"; exit 1; }
echo "   rtl: $(wc -l < "$RTL") records"

echo "== 4. grade: compare.py --mode func (x87 auto-graded: both headers x87) =="
set +e
"$PY" "$CMP" --mode func --all "$GOLDEN" "$RTL"
RC=$?
set -e
echo
if [[ "$RC" == 0 ]]; then
  echo "BENCH-LOCKSTEP-OK: $TAG  $N-insn prefix EQUIVALENT (RTL bit-exact vs QEMU)"
else
  echo "BENCH-LOCKSTEP-DIVERGENT: $TAG  — first-divergence record above"
  echo "  (a CPU bug unless it is an unmodeled syscall / host-id nondeterminism)"
fi
exit $RC
