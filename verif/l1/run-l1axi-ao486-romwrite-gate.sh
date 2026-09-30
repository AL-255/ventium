#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Production cache-path contract, intentionally RED on the unfixed design.
# EXPECT_RED=1 verifies the known ROM/cache mismatch, never a compile failure.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH_ROOT="$ROOT/verif/l1/obj_dir_store_policy_scratch"
mkdir -p "$SCRATCH_ROOT"
[[ "$(readlink -f "$SCRATCH_ROOT")" == "$SCRATCH_ROOT" ]] || {
    echo "Refusing symlinked cache-policy scratch" >&2; exit 2;
}
# Do this before entering the scope: its generic TMPDIR default can resolve to
# the unrelated, nearly-full external-volume symlink at repo tmp/build-tmp.
export TMPDIR="$SCRATCH_ROOT/build-tmp"
mkdir -p "$TMPDIR"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi
[[ "${EXPECT_RED:-0}" == 0 || "${EXPECT_RED:-0}" == 1 ]] || exit 2
[[ "${STORE_POLICY:-1}" == 0 || "${STORE_POLICY:-1}" == 1 ]] || exit 2
OUT="$(mktemp -d "$SCRATCH_ROOT/ventium-l1axi-ao486-romwrite.XXXXXX")"
echo "Artifacts: $OUT"
SOURCE_ROOT="${ROMWRITE_SOURCE_ROOT:-$ROOT}"
[[ "$SOURCE_ROOT" = /* && -d "$SOURCE_ROOT" ]] || exit 2
sources=(rtl/mem/ven_cdc_afifo.sv rtl/mem/ven_reset_sync.sv rtl/mem/ven_axi_cdc.sv
    rtl/mem/ven_l1d.sv rtl/mem/ven_axi_master.sv rtl/northbridge/ven_cachemap.sv
    rtl/mem/ventium_l1_axi.sv ao486-sim/ven/ven_axi2avalon.sv
    3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v ao486-sim/stubs/sim_prims.sv
    verif/l1/tb_l1axi_ao486_romwrite.sv verif/l1/romwrite_ao486_primitive.vlt)
build_sources=()
for relative in "${sources[@]}"; do
    mkdir -p "$OUT/src/$(dirname "$relative")"
    input_root="$SOURCE_ROOT"
    [[ "$relative" != verif/* ]] || input_root="$ROOT"
    cp -p "$input_root/$relative" "$OUT/src/$relative"
    build_sources+=("$OUT/src/$relative")
done
cp -p "$0" "$OUT/src/verif/l1/run-l1axi-ao486-romwrite-gate.sh"
sha256sum "${build_sources[@]}" "$OUT/src/verif/l1/run-l1axi-ao486-romwrite-gate.sh" > "$OUT/source.sha256"
defs=(+define+VEN_L1D_CODE_BUFFER +define+VEN_L1D_CODE_TAG_INVALIDATE
    +define+VEN_L1D_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE
    +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_TWO_WINDOW_KEEP_STORE
    +define+VEN_L1D_TAG_INVALIDATE +define+VEN_L1D_FILL_FORWARD
    +define+VEN_L1D_HIT_UNDER_FILL +define+VEN_AXI2AVL_ASSERT)
[[ "${STORE_POLICY:-1}" != 1 ]] || defs+=(+define+VEN_L1D_STORE_POLICY)
for profile in packed banked banked_pair; do
    extra=(); [[ "$profile" == packed ]] || extra+=(+define+VEN_L1D_BANKED_DATA)
    [[ "$profile" != banked_pair ]] || extra+=(+define+VEN_P54_DUAL_STORE_PAIR)
    mkdir -p "$OUT/$profile"
    printf '%s\n' "${defs[@]}" "${extra[@]}" > "$OUT/$profile/defines.txt"
    "$ROOT/tools/verilator_serial.sh" -j1 --binary --timing --assert -sv -Wall \
        -Wno-UNUSED -Wno-fatal \
        -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
        -Werror-LATCH -Werror-UNOPTFLAT "${defs[@]}" "${extra[@]}" \
        --top-module tb_l1axi_ao486_romwrite -Mdir "$OUT/$profile" -o test \
        "${build_sources[@]}" > "$OUT/$profile.build.log" 2>&1 \
        || { tail -50 "$OUT/$profile.build.log"; exit 1; }
    rc=0
    timeout --kill-after=2s 30s "$OUT/$profile/test" > "$OUT/$profile.run.log" 2>&1 || rc=$?
    if [[ "${EXPECT_RED:-0}" == 1 ]]; then
        [[ "$rc" != 0 && "$rc" != 124 && "$rc" != 137 ]] || { tail -25 "$OUT/$profile.run.log"; exit 1; }
        grep -q 'ROMWRITE-CACHE-FAIL' "$OUT/$profile.run.log"
        ! grep -q 'ROMWRITE-RAM-CONTROL-FAIL' "$OUT/$profile.run.log"
        grep -q 'ROMWRITE-RESULT .*ram_errors=0 ' "$OUT/$profile.run.log"
        echo "ROMWRITE-EXPECTED-RED profile=$profile"
    else
        [[ "$rc" == 0 ]] || { tail -25 "$OUT/$profile.run.log"; exit 1; }
        grep -q 'ROMWRITE-CACHE-OK' "$OUT/$profile.run.log"
    fi
    grep 'ROMWRITE-RESULT\|ROMWRITE-RAM-CONTROL' "$OUT/$profile.run.log"
done
sha256sum -c "$OUT/source.sha256" > "$OUT/source-stability.log"
sha256sum "$OUT/packed/test" "$OUT/banked/test" "$OUT/banked_pair/test" > "$OUT/binaries.sha256"
echo "ROMWRITE-PATH-GATE-OK expect_red=${EXPECT_RED:-0} $OUT"
