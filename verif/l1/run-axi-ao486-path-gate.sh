#!/usr/bin/env bash
# Production master + bridge + actual ao486 cache, same-work replay A/B.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi-ao486-path.XXXXXX")"
echo "Artifacts: $OBJ"
for stream in 0 1 2; do
  extra=()
  if [[ "$stream" != 0 ]]; then extra+=(-DVEN_L2_STREAM_CWF); fi
  if [[ "$stream" == 2 ]]; then extra+=(-DVEN_L2_STREAM_ANY); fi
  for replay in 0 1; do
    tag="s${stream}-r${replay}"
    "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -sv \
      -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
      -Wno-PINMISSING -Wno-PINCONNECTEMPTY "${extra[@]}" -GREPLAY="$replay" \
      --top-module tb_axi_ao486_path -Mdir "$OBJ/$tag" -o test \
      "$ROOT/rtl/mem/ven_axi_master.sv" \
      "$ROOT/ao486-sim/ven/ven_axi2avalon.sv" \
      "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
      "$ROOT/ao486-sim/stubs/sim_prims.sv" \
      "$ROOT/verif/l1/tb_axi_ao486_path.sv" >"$OBJ/$tag.build.log" 2>&1 \
      || { tail -50 "$OBJ/$tag.build.log"; exit 1; }
    "$OBJ/$tag/test" >"$OBJ/$tag.run.log" 2>&1 \
      || { cat "$OBJ/$tag.run.log"; exit 1; }
    grep 'AXI-AO486-PATH-OK' "$OBJ/$tag.run.log"
  done
  single=$(sed -n 's/.*read_clocks=\([0-9]*\).*/\1/p' "$OBJ/s$stream-r0.run.log")
  replayed=$(sed -n 's/.*read_clocks=\([0-9]*\).*/\1/p' "$OBJ/s$stream-r1.run.log")
  [[ -n "$single" && -n "$replayed" && "$single" -lt "$replayed" ]] \
    || { echo "AXI-AO486-PATH-FAIL: no same-work cycle improvement"; exit 1; }
done
echo AXI-AO486-PATH-GATE-OK
