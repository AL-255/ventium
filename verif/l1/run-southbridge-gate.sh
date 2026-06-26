#!/usr/bin/env bash
# verif/l1/run-southbridge-gate.sh — Phase D.2 gate: the ven_southbridge wrapper shell.
# Builds tb_southbridge and asserts SOUTHBRIDGE-GATE-OK: PCI config via port-I/O
# (0xCF8/0xCFC) drives the host-bridge cfg_* outputs; the MMIO slave serves the VGA-aperture
# framebuffer (write/read-back); the DMA control block programs ven_i8237_dma which
# bus-masters a device→mem transfer on the dma_* master. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    --top-module tb_southbridge -Mdir "$OBJ" -o tb_southbridge \
    "$ROOT/rtl/northbridge/ven_hostbridge_cfg.sv" "$ROOT/rtl/soc/ven_i8237_dma.sv" \
    "$ROOT/rtl/northbridge/ven_southbridge.sv" "$ROOT/verif/l1/tb_southbridge.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "SOUTHBRIDGE-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_southbridge" 2>&1)"
echo "$OUT"
grep -q "SOUTHBRIDGE-GATE-OK" <<<"$OUT" || { echo "SOUTHBRIDGE-GATE-FAIL"; exit 1; }
echo "== ven_southbridge wrapper gate PASS =="
