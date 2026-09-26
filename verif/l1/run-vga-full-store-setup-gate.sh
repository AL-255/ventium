#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Verify byte traffic, reset quiescence, and the one-cycle full-store saving.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
  exit 2
fi
OUT="$(realpath -m -- "$1")"
mkdir -p "$OUT"
for profile in off on; do
  mkdir "$OUT/$profile"
  defs=()
  args=()
  if [ "$profile" = on ]; then
    defs=(-DVEN_VGA_FULL_STORE_SETUP)
    args=(+require_saved)
  fi
  "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -sv -j 1 \
    "${defs[@]}" -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
    -Wno-DECLFILENAME -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    --top-module tb_vga_full_store_setup \
    -Mdir "$OUT/$profile" -o tb_vga_full_store_setup \
    "$ROOT/verif/l1/tb_vga_full_store_setup.sv" \
    "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
    "$ROOT/ao486-sim/stubs/sim_prims.sv" \
    >"$OUT/$profile/build.log" 2>&1 || {
      tail -40 "$OUT/$profile/build.log"; exit 1;
    }
  "$OUT/$profile/tb_vga_full_store_setup" "${args[@]}" \
    >"$OUT/$profile/run.log" 2>&1 || {
      tail -40 "$OUT/$profile/run.log"; exit 1;
    }
  rg -q "VGA-FULL-STORE-SETUP-OK enabled=$([ "$profile" = on ] && echo 1 || echo 0)" \
    "$OUT/$profile/run.log"
done
diff -u <(rg '^(BYTE|DDR) ' "$OUT/off/run.log") \
        <(rg '^(BYTE|DDR) ' "$OUT/on/run.log")
echo "VGA-FULL-STORE-SETUP-GATE-OK"
