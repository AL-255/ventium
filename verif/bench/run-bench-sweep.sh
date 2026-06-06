#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-bench-sweep.sh — parallel benchmark differential lock-step sweep.
#
# Builds the RTL TB ONCE, then runs a diverse set of standard-benchmark
# configurations through run-bench-lockstep.sh CONCURRENTLY (each its own gdbstub
# port + build/bench/<tag>/ output dir, so they never race), and prints a single
# pass/fail table. The configs are chosen to span the instruction mix the directed
# corpus under-covers: integer list/CRC/state-machine (coremark, kernels crc32),
# integer multiply/recursion (kernels matmul_int/nqueens/sieve), and long x87 FP
# chains (whetstone, stream, kernels matmul_fp).
#
#   bash verif/bench/run-bench-sweep.sh [N_INSNS] [JOBS]
#     N_INSNS  per-config retired-instruction prefix to grade (default 250000).
#     JOBS     max concurrent configs (default min(nproc-2, #configs)).
#
# Exit 0 IFF every config's graded prefix is EQUIVALENT.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$REPO/verif/bench/run-bench-lockstep.sh"
N="${1:-250000}"
NCPU="$(nproc 2>/dev/null || echo 4)"; [ "$NCPU" -gt 3 ] && NCPU=$(( NCPU - 2 ))
JOBS="${2:-$NCPU}"

# tag|port|bench|argv...   (argv after the bench name; '-' = none)
CONFIGS=(
  "coremark|53100|coremark|-"
  "whetstone|53101|whetstone|-"
  "stream|53102|stream|-"
  "k_sieve|53103|kernels|sieve 500000"
  "k_matmul_int|53104|kernels|matmul_int 80"
  "k_matmul_fp|53105|kernels|matmul_fp 80"
  "k_crc32|53106|kernels|crc32 2000000"
  "k_nqueens|53107|kernels|nqueens 11"
)

echo "######################################################################"
echo "# bench-sweep: ${#CONFIGS[@]} configs, N=$N insns each, up to $JOBS parallel"
echo "######################################################################"

echo "== build the RTL TB ONCE (verif/tb) =="
make -C "$REPO/verif/tb" rtl >/dev/null || { echo "RTL build failed"; exit 1; }

OUT="$REPO/build/bench"; mkdir -p "$OUT"
run_one() {  # tag port bench argstr
  local tag="$1" port="$2" bench="$3" argstr="$4"
  local log="$OUT/$tag.sweep.log"
  local -a a=()
  [[ "$argstr" != "-" ]] && read -r -a a <<< "$argstr"
  if [[ ${#a[@]} -gt 0 ]]; then
    BENCH_SKIP_BUILD=1 bash "$RUN" "$bench" "$N" "$port" -- "${a[@]}" > "$log" 2>&1
  else
    BENCH_SKIP_BUILD=1 bash "$RUN" "$bench" "$N" "$port" > "$log" 2>&1
  fi
  echo "$?" > "$OUT/$tag.sweep.rc"
}
export -f run_one; export OUT N RUN

printf '%s\n' "${CONFIGS[@]}" | \
  xargs -P "$JOBS" -I{} -d '\n' bash -c '
    IFS="|" read -r tag port bench argstr <<< "{}"
    echo "  [start] $tag ($bench $argstr) port $port"
    run_one "$tag" "$port" "$bench" "$argstr"
    echo "  [done ] $tag rc=$(cat "'"$OUT"'/$tag.sweep.rc")"
  '

echo
echo "######################################################################"
echo "# bench-sweep — SUMMARY"
echo "######################################################################"
FAIL=0
for c in "${CONFIGS[@]}"; do
  IFS="|" read -r tag port bench argstr <<< "$c"
  rc="$(cat "$OUT/$tag.sweep.rc" 2>/dev/null || echo "??")"
  verd="$(grep -hoE 'BENCH-LOCKSTEP-(OK|DIVERGENT).*' "$OUT/$tag.sweep.log" 2>/dev/null | head -1)"
  [[ -z "$verd" ]] && verd="(no verdict — see $OUT/$tag.sweep.log)"
  if [[ "$rc" == "0" ]]; then st="PASS"; else st="FAIL"; FAIL=1; fi
  printf "  %-6s %-14s %s\n" "$st" "$tag" "$verd"
done
echo
[[ "$FAIL" == "0" ]] && echo "BENCH-SWEEP-OK (every config EQUIVALENT)" || echo "BENCH-SWEEP: divergence(s) above — triage each log in $OUT/"
exit $FAIL
