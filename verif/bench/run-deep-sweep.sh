#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-deep-sweep.sh — DEEP + DIVERSE + parallel per-instruction differential.
#
# Builds the RTL TB once, then runs a broad matrix of standard-benchmark
# configurations through run-deep-lockstep.sh (compressed, O(1)-disk, every
# retired instruction graded vs QEMU incl. x87). The matrix spans the full
# instruction mix the directed corpus under-covers AND multiple workload
# sizes/seeds per kernel, so a data-dependent bug has many chances to surface.
#
# Concurrency is DISK-bounded (each in-flight config holds its compressed
# golden+RTL traces until its compare finishes, then frees them), not CPU-bound —
# the single-step gdbstub oracle (~10k insn/s) is the wall-time floor, so we run
# as many producers in parallel as the free disk safely allows.
#
#   bash verif/bench/run-deep-sweep.sh [JOBS]
#     JOBS  max concurrent configs (default 4 — memory-conservative; each config
#           is a single-step producer + a Verilator TB + a streaming comparator).
#
# Per-config verdicts land in build/deep/<tag>/verdict.txt; this prints a table.
# Exit 0 IFF every config is EQUIVALENT.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$REPO/verif/bench/run-deep-lockstep.sh"
JOBS="${1:-4}"
OUT="$REPO/build/deep"; mkdir -p "$OUT"

# tag | port | max_insn | stdin | bench | argv...
# (stdin '-' = none; argv '-' = none). Sizes chosen so the bounded workloads RUN
# TO EXIT within the cap (full entry->exit grading); Quake never exits (prefix).
CONFIGS=(
  "cm_n10|54000|8000000|-|coremark|0x0 0x0 0x66 10"
  "cm_n40|54001|22000000|-|coremark|0x0 0x0 0x66 40"
  "cm_seedA|54002|14000000|-|coremark|0x1 0x2 0x3 30"
  "cm_seedB|54003|14000000|-|coremark|0x7 0xd 0x11 30"
  "whetstone|54004|45000000|-|whetstone|-"
  "stream|54005|45000000|-|stream|-"
  "dhry_100k|54006|14000000|-|dhrystone|100000"
  "linpack_100|54007|35000000|100\\nq\\n|linpack|-"
  "k_sieve_2k|54008|20000000|-|kernels|sieve 2000"
  "k_sieve_500k|54009|45000000|-|kernels|sieve 500000"
  "k_mmi_100|54010|20000000|-|kernels|matmul_int 100"
  "k_mmi_180|54011|45000000|-|kernels|matmul_int 180"
  "k_mmf_100|54012|20000000|-|kernels|matmul_fp 100"
  "k_mmf_180|54013|45000000|-|kernels|matmul_fp 180"
  "k_crc_8|54014|20000000|-|kernels|crc32 8"
  "k_crc_64|54015|45000000|-|kernels|crc32 64"
  "k_nq_11|54016|20000000|-|kernels|nqueens 11"
  "k_nq_12|54017|45000000|-|kernels|nqueens 12"
  "quake_30M|54018|30000000|-|quake|-"
)

echo "######################################################################"
echo "# deep-sweep: ${#CONFIGS[@]} configs, up to $JOBS parallel (disk-bounded)"
echo "# free disk: $(df -h "$REPO" | awk 'NR==2{print $4}')"
echo "######################################################################"
echo "== build the RTL TB ONCE =="
make -C "$REPO/verif/tb" rtl >/dev/null || { echo "RTL build failed"; exit 1; }

run_one() {  # cfg-line
  local cfg="$1"; IFS="|" read -r tag port maxn stdin bench argv <<< "$cfg"
  local -a a=()
  [[ "$argv" != "-" ]] && read -r -a a <<< "$argv"
  echo "  [start] $tag ($bench ${argv}) N=$maxn port=$port"
  if [[ ${#a[@]} -gt 0 ]]; then
    bash "$RUN" "$bench" "$maxn" "$port" "$stdin" -- "${a[@]}" > "$OUT/$tag.run.log" 2>&1
  else
    bash "$RUN" "$bench" "$maxn" "$port" "$stdin" > "$OUT/$tag.run.log" 2>&1
  fi
  echo "$?" > "$OUT/$tag.rc"
  echo "  [done ] $tag rc=$(cat "$OUT/$tag.rc")  (free: $(df -h "$REPO" | awk 'NR==2{print $4}'))"
}
export -f run_one; export RUN OUT

printf '%s\n' "${CONFIGS[@]}" | xargs -P "$JOBS" -I{} -d '\n' bash -c 'run_one "$@"' _ {}

echo
echo "######################################################################"
echo "# deep-sweep — SUMMARY"
echo "######################################################################"
FAIL=0
for c in "${CONFIGS[@]}"; do
  IFS="|" read -r tag _ _ _ _ _ <<< "$c"
  rc="$(cat "$OUT/$tag.rc" 2>/dev/null || echo '??')"
  v="$(grep -hoE 'DEEP-LOCKSTEP-(OK|DIVERGENT).*' "$OUT/$tag.run.log" 2>/dev/null | head -1)"
  [[ -z "$v" ]] && v="$(grep -hoE '(PRODUCER|TB)-FAIL.*' "$OUT/$tag.run.log" 2>/dev/null | head -1)"
  [[ -z "$v" ]] && v="(no verdict — see $OUT/$tag.run.log)"
  if [[ "$rc" == "0" ]]; then st="PASS"; else st="FAIL"; FAIL=1; fi
  printf "  %-6s %-14s %s\n" "$st" "$tag" "$v"
done
echo
[[ "$FAIL" == "0" ]] && echo "DEEP-SWEEP-OK (every config EQUIVALENT)" || echo "DEEP-SWEEP: divergence(s)/error(s) above — triage build/deep/<tag>/verdict.txt"
exit $FAIL
