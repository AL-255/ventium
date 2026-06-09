#!/usr/bin/env bash
# verif/soc/run-soc-axil-gate.sh — unit gate for ven_soc_axil (KV260 PS<->PL bridge).
# Builds tb_ven_soc_axil with Verilator --binary and asserts SOCAXIL-GATE-OK (the
# AXI-Lite control/config/status/retire registers + the port-I/O capture/release
# handshake where the core stalls on io_ack until the PS services it). Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-WIDTHEXPAND \
    --top-module tb_ven_soc_axil -Mdir "$OBJ" -o tb_ven_soc_axil \
    "$ROOT/rtl/soc/ven_soc_axil.sv" "$ROOT/verif/soc/tb_ven_soc_axil.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "SOCAXIL-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_ven_soc_axil" 2>&1)"
echo "$OUT"
grep -q "SOCAXIL-GATE-OK" <<<"$OUT" || { echo "SOCAXIL-GATE-FAIL"; exit 1; }
echo "== ven_soc_axil unit gate PASS =="
