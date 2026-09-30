#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# CL normal shifts/rotates: zero/one/general/masked-zero counts, widths and AH.
# No RCL/RCR acceleration, build, benchmark scoring, or saved state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the four-clock CL occupancy candidate binary}"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-cl-execution.XXXXXX)}"
mkdir -p "$OUT"
for op in 7 8 9 10 11; do
  for width in 8 16 32; do
    for memory in 0 1; do
      for count in 0 1 3 32; do
        name="${op}_${width}_${memory}_c${count}"
        CASE_ONLY="${op}_${width}_${memory}" CL_COUNT="$count" \
          OUTDIR="$OUT/$name" bash "$ROOT/verif/issue_uv/run-int-execution-latency.sh" \
          > "$OUT/$name.log" 2>&1 || { tail -n 30 "$OUT/$name.log"; exit 1; }
        rg '^.*QEMU state checked;' "$OUT/$name.log"
      done
    done
  done
  for count in 0 1 3 32; do
    name="${op}_8_high_c${count}"
    CASE_ONLY="${op}_8_0" CL_COUNT="$count" HIGH8=1 OUTDIR="$OUT/$name" \
      bash "$ROOT/verif/issue_uv/run-int-execution-latency.sh" \
      > "$OUT/$name.log" 2>&1 || { tail -n 30 "$OUT/$name.log"; exit 1; }
    rg '^.*QEMU state checked;' "$OUT/$name.log"
  done
done
printf 'CL-EXECUTION-LATENCY-OK artifacts=%s\n' "$OUT"
