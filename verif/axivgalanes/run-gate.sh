#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# == 2 && "$1" == --out ]] || { echo 'usage: bash verif/axivgalanes/run-gate.sh --out FRESH_OWNED_OUTPUT'; exit 2; }
out="$(realpath -- "$2")"
[[ -d "$out" && ! -e "$out/inputs.before.sha256" && "$(stat -c %u "$out")" == "$UID" ]] || exit 2
case "$out" in "$repo"/verif/l1/obj_dir_axivgalanes_*) ;; *) exit 2 ;; esac
export TMPDIR="$out/compiler-tmp"
mkdir -m 700 "$TMPDIR"
export VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32
export AXIVGALANES_BRIDGE_ASSERT="${AXIVGALANES_BRIDGE_ASSERT:-0}"
[[ "$AXIVGALANES_BRIDGE_ASSERT" == 0 || "$AXIVGALANES_BRIDGE_ASSERT" == 1 ]] || exit 2
export AXIVGALANES_HOLD="${AXIVGALANES_HOLD:-0}"
[[ "$AXIVGALANES_HOLD" == 0 || "$AXIVGALANES_HOLD" == 1 ]] || exit 2
cd "$repo"
sha256sum ao486-sim/ven/ven_axi2avalon.sv 3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v \
  ao486-sim/stubs/sim_prims.sv verif/axivgalanes/tb_axivgalanes.sv \
  verif/axivgalanes/tb_axivgalanes_hold.sv \
  verif/l1/romwrite_ao486_primitive.vlt \
  verif/axivgalanes/run-gate.sh verif/fetchguard/record_resources.py tools/build_scope.sh \
  > "$out/inputs.before.sha256"
printf '%s\n' "$AXIVGALANES_BRIDGE_ASSERT" > "$out/bridge-assert.enabled"
printf '%s\n' "$AXIVGALANES_HOLD" > "$out/hold-variant.enabled"
set +e
timeout --signal=TERM --kill-after=10s 540s tools/build_scope.sh -- bash -c '
  set -euo pipefail; repo="$1"; out="$2"; ulimit -c 0; export CCACHE_DISABLE=1;
  "$repo/tools/build_scope.sh" --is-active;
  python3 "$repo/verif/fetchguard/record_resources.py" --phase before --out "$out/resources.before.json";
  trap '\''python3 "$repo/verif/fetchguard/record_resources.py" --phase after --out "$out/resources.after.json"'\'' EXIT;
  top=tb_axivgalanes;
  if [[ "$AXIVGALANES_HOLD" == 1 ]]; then top=tb_axivgalanes_hold; fi;
  any_red=0;
  for profile in baseline production; do
    defs=(); if [[ "$profile" == production ]]; then
      defs=(-DVEN_AXI2AVL_BPIPE -DVEN_AXI2AVL_WRITE_THROUGH -DVEN_VGA_FULL_STORE_SETUP -DVEN_VGA_WIDE_STORE);
    fi;
    if [[ "$AXIVGALANES_BRIDGE_ASSERT" == 1 ]]; then defs+=(-DVEN_AXI2AVL_ASSERT); fi;
    mkdir "$out/$profile";
    verilator --binary --timing --assert -sv -j 32 -Wall -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING \
      -Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
      "${defs[@]}" --top-module "$top" -Mdir "$out/$profile/obj" -o tb_axivgalanes \
      "$repo/verif/l1/romwrite_ao486_primitive.vlt" \
      "$repo/verif/axivgalanes/$top.sv" "$repo/ao486-sim/ven/ven_axi2avalon.sv" \
      "$repo/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" "$repo/ao486-sim/stubs/sim_prims.sv" \
      > "$out/$profile/build.log" 2>&1;
    set +e; "$out/$profile/obj/tb_axivgalanes" > "$out/$profile/run.log" 2>&1; native="$?"; set -e;
    printf "%s\n" "$native" > "$out/$profile/native.exit";
    [[ "$native" == 0 ]] || any_red=1;
  done;
  exit "$any_red"' bash "$repo" "$out"
status="$?"
set -e
printf '%s\n' "$status" > "$out/gate.exit"
sha256sum --check "$out/inputs.before.sha256" > "$out/input-check.after.log"
for profile in baseline production; do
  if [[ -e "$out/$profile/run.log" ]]; then rg 'AXIVGALANES-(SUMMARY|GATE)' "$out/$profile/run.log" || true; fi
done
echo "AXIVGALANES runner exit=$status artifacts=$out"
exit "$status"
