#!/usr/bin/env bash
# verif/l1/run-l1axi-cdc-verify.sh — P1-3 dual-clock cosim functional gate.
# Reuses run-l1axi-verify.sh verbatim but builds the +VEN_AXI_CDC tb (l1axi_cdc) so
# the WHOLE 77-program suite boots through the ven_axi_cdc bridge (core_clk==axi_clk
# in the cosim — the degenerate equal-clock ratio; the multi-ratio data-integrity
# proof is run-l1axi-cdc-gate.sh). A separate obj dir / workdir / portbase keeps it
# independent of the single-clock l1axi build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export L1AXI_TARGET="l1axi_cdc"
export L1AXI_TB_BIN="$ROOT/verif/tb/obj_dir_l1axi_cdc/tb_ventium"
export L1AXI_WORKDIR="$ROOT/build/verify-l1axi-cdc"
export PORTBASE="${PORTBASE:-28000}"
exec bash "$ROOT/verif/l1/run-l1axi-verify.sh"
