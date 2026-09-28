#!/usr/bin/env bash
# Bounded production master -> bridge -> ao486 L2 write-stream A/B.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi-write-pipe.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT

build_run() {
  local tag="$1"
  shift
  timeout 420 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-4}" --binary --timing --assert -sv \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -DVEN_P54_WRITE_PIPE_TEST -DVEN_AXI2AVL_ASSERT "$@" \
    -GREPLAY=0 --top-module tb_axi_ao486_path -Mdir "$OBJ/$tag" -o test \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/ao486-sim/ven/ven_axi2avalon.sv" \
    "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
    "$ROOT/ao486-sim/stubs/sim_prims.sv" \
    "$ROOT/verif/l1/tb_axi_ao486_path.sv" >"$OBJ/$tag.build.log" 2>&1 \
    || { tail -50 "$OBJ/$tag.build.log"; return 1; }
  timeout 60 "$OBJ/$tag/test" >"$OBJ/$tag.run.log" 2>&1 \
    || { cat "$OBJ/$tag.run.log"; return 1; }
  grep 'AXI-AO486-WRITE-PIPE\|AXI-AO486-PATH-OK' "$OBJ/$tag.run.log"
}

build_run control & control_pid=$!
build_run master_only -DVEN_P54_WBUF_PIPE_DISPATCH & master_pid=$!
build_run bridge_only -DVEN_AXI2AVL_BPIPE & bridge_pid=$!
build_run candidate -DVEN_P54_WBUF_PIPE_DISPATCH -DVEN_AXI2AVL_BPIPE & candidate_pid=$!
wait "$control_pid"
wait "$master_pid"
wait "$bridge_pid"
wait "$candidate_pid"
control=$(sed -n 's/.*AXI-AO486-WRITE-PIPE clocks=\([0-9]*\).*/\1/p' "$OBJ/control.run.log")
master_only=$(sed -n 's/.*AXI-AO486-WRITE-PIPE clocks=\([0-9]*\).*/\1/p' "$OBJ/master_only.run.log")
bridge_only=$(sed -n 's/.*AXI-AO486-WRITE-PIPE clocks=\([0-9]*\).*/\1/p' "$OBJ/bridge_only.run.log")
candidate=$(sed -n 's/.*AXI-AO486-WRITE-PIPE clocks=\([0-9]*\).*/\1/p' "$OBJ/candidate.run.log")
[[ -n "$control" && -n "$master_only" && -n "$bridge_only" && -n "$candidate" && "$candidate" -lt "$control" ]] \
  || { echo "AXI-AO486-WRITE-PIPE-FAIL: control=$control master_only=$master_only bridge_only=$bridge_only candidate=$candidate"; exit 1; }
echo "AXI-AO486-WRITE-PIPE-GATE-OK control=$control master_only=$master_only bridge_only=$bridge_only candidate=$candidate"
