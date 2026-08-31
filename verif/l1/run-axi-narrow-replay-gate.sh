#!/usr/bin/env bash
# KV260 DDR-only narrow-read replay regression.  This complements
# run-l1axi-narrow-gate.sh, which proves that the default device/MMIO mode still
# emits exactly one AR and therefore does not duplicate read side effects.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
    --top-module tb_axi_narrow_replay -Mdir "$OBJ/obj" -o tb_axi_narrow_replay \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_narrow_replay.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-NARROW-REPLAY-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_narrow_replay" 2>&1)"
echo "$OUT"
grep -q "AXI-NARROW-REPLAY-GATE-OK" <<<"$OUT" \
    || { echo "AXI-NARROW-REPLAY-GATE-FAIL"; exit 1; }
