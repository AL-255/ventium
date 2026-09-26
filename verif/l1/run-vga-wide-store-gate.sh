#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Compare plane RAM contents after legacy and qualified 32-bit VGA stores.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
  exit 2
fi
OUT="$(realpath -m -- "$1")"
mkdir -p "$OUT"
for profile in no_setup setup; do
  mkdir "$OUT/$profile"
  defs=()
  if [ "$profile" = setup ]; then defs=(-DVEN_VGA_FULL_STORE_SETUP); fi
  "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -sv -j 1 \
    -DVEN_VGA_WIDE_STORE "${defs[@]}" \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    --top-module tb_vga_wide_store -Mdir "$OUT/$profile" -o tb_vga_wide_store \
    "$ROOT/verif/l1/tb_vga_wide_store.sv" \
    "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
    "$ROOT/3rd-party/ao486_MiSTer/rtl/soc/vga.v" \
    "$ROOT/ao486-sim/stubs/sim_prims.sv" >"$OUT/$profile/build.log" 2>&1 || {
      tail -60 "$OUT/$profile/build.log"; exit 1;
    }
  "$OUT/$profile/tb_vga_wide_store" >"$OUT/$profile/run.log" 2>&1 || {
    tail -60 "$OUT/$profile/run.log"; exit 1;
  }
  rg -q 'VGA-WIDE-STORE-OK cases=18' "$OUT/$profile/run.log"
done
echo VGA-WIDE-STORE-GATE-OK
