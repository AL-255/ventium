#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-lint-gate.sh — the canonical lint matrix. The structural warning classes
# that have bitten this tree (an implicit net at a configuration boundary, a
# missing pin on a define-variant instance, an undriven tie-off, a multiply
# driven register, an inferred latch, combinational loops) are HARD ERRORS in
# every build configuration below; style/width noise stays visible but
# non-fatal.
#
# Configurations: the default build, the L1/AXI build, the deployed KV260
# define set (mirrors KV_FULL_DEFS in verif/tb/Makefile), the iterative-BCD
# variant, and the deployed FP_PS_ALL area-relief variant (KV minus the six
# area-bulk defines, plus VEN_FP_PS_ALL + VEN_FPTRAP).
#
# Prints LINT-GATE-OK on success.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO/rtl"

FATAL="-Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT"
BASE="--lint-only -sv -Wall -Wno-UNUSED -Wno-fatal $FATAL --top-module ventium_top -f ventium.f +define+VTM_NO_DPI"

KV_DEFS="+define+VEN_L1_AXI +define+VEN_KV260_SOC +define+VEN_FE_PIPE \
+define+VEN_UOPCACHE +define+VEN_BTB_PIPE +define+VEN_IC_BRAM +define+VEN_CACHE_HALF \
+define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_SRT_ITER +define+VEN_IDIV_ITER \
+define+VEN_BCD_ITER +define+VEN_FP_PC_RELAX +define+VEN_FPREM"
# The deployed area-relief profile: KV minus FP_PIPE/FP_PIPE2/SRT_ITER/BCD_ITER,
# plus FP_PS_ALL + FPTRAP (mirrors KV_FPPS_DEFS in verif/tb/Makefile).
FPPS_DEFS="+define+VEN_L1_AXI +define+VEN_KV260_SOC +define+VEN_FE_PIPE \
+define+VEN_UOPCACHE +define+VEN_BTB_PIPE +define+VEN_IC_BRAM +define+VEN_CACHE_HALF \
+define+VEN_IDIV_ITER +define+VEN_FP_PC_RELAX +define+VEN_FP_PS_ALL +define+VEN_FPTRAP"

# The L1/AXI configurations need the memory-hierarchy modules, which are not in
# ventium.f (mirrors L1AXI_RTL in verif/tb/Makefile).
L1AXI_RTL="mem/ven_l1d.sv mem/ven_axi_master.sv mem/ventium_l1_axi.sv northbridge/ven_cachemap.sv"

fails=0
run_cfg() {
  local name="$1"; shift
  local extra=""
  if [[ " $* " == *"+define+VEN_L1_AXI"* ]]; then extra="$L1AXI_RTL"; fi
  local out rc
  set +e
  out="$(verilator $BASE "$@" $extra 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL: lint config $name (rc=$rc)"
    echo "$out" | grep -E "%Error" | head -10 | sed 's/^/        /'
    fails=1
  else
    local n
    n="$(grep -cE '%Warning' <<<"$out" || true)"
    echo "  ok   $name (0 fatal-class findings; $n non-fatal warnings)"
  fi
}

echo "== lint matrix (fatal: IMPLICIT PINMISSING UNDRIVEN MULTIDRIVEN LATCH UNOPTFLAT) =="
run_cfg default
run_cfg l1axi        +define+VEN_L1_AXI
run_cfg kv260        $KV_DEFS
run_cfg bcd_iter     +define+VEN_BCD_ITER
run_cfg fp_ps_all    $FPPS_DEFS

if [[ "$fails" == "0" ]]; then echo "LINT-GATE-OK"; else echo "LINT-GATE-FAIL"; exit 1; fi
