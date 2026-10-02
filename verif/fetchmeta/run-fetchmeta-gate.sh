#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Standalone decoder metadata checks, not a system/differential/standard-suite
# gate. Covers authorized raw opcode headers, ignored suffixes, body lengths,
# and the first atomic overlength endpoint. It cannot prove CPU trap ordering,
# paging/segment permissions, held bus packets, or software compatibility.
set -euo pipefail
ulimit -c 0
fetchmeta_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "${1:-}" != --inner ]]; then
    [[ "$#" == 0 ]] || { echo 'usage: bash run-fetchmeta-gate.sh' >&2; exit 2; }
    # The default is /tmp; an explicit root-backed repo testbench parent avoids
    # /tmp's per-user quota. These are the only allowed parents. No existing
    # directory is reused or removed, even after failure. Global df free space
    # is only an initial check, never evidence of available per-user quota.
    fetchmeta_parent="${FETCHMETA_SCRATCH_PARENT:-/tmp}"
    [[ "$fetchmeta_parent" == /tmp ||
       "$fetchmeta_parent" == "$fetchmeta_repo/verif/tb" ]] || {
        echo 'FETCHMETA: scratch parent must be /tmp or this repo verif/tb' >&2; exit 2;
    }
    [[ -d "$fetchmeta_parent" &&
       "$(readlink -f -- "$fetchmeta_parent")" == "$fetchmeta_parent" ]] || {
        echo 'FETCHMETA: scratch parent must be a canonical directory' >&2; exit 2;
    }
    if [[ "$fetchmeta_parent" == /tmp ]]; then
        [[ "$(stat -c %u -- "$fetchmeta_parent")" == 0 &&
           -k "$fetchmeta_parent" && -w "$fetchmeta_parent" && -x "$fetchmeta_parent" ]] || {
            echo 'FETCHMETA: /tmp must be root-owned, sticky, and writable' >&2; exit 2;
        }
    else
        [[ "$(stat -c %u -- "$fetchmeta_parent")" == "$UID" ]] || {
            echo 'FETCHMETA: repo scratch parent must be owned by this uid' >&2; exit 2;
        }
    fi
    fetchmeta_free_kb="$(df -Pk "$fetchmeta_parent" | awk 'NR==2 {print $4}')"
    [[ "$fetchmeta_free_kb" =~ ^[0-9]+$ ]] && ((fetchmeta_free_kb>=262144)) || {
        echo 'FETCHMETA: scratch volume needs at least256MiB global free; no build launched' >&2; exit 2;
    }
    if [[ "$fetchmeta_parent" == /tmp ]]; then
        fetchmeta_out="$(mktemp -d /tmp/fetchmeta.XXXXXX)"
    else
        fetchmeta_out="$(mktemp -d "$fetchmeta_parent/obj_dir_fetchmeta_oct02.XXXXXX")"
    fi
    mkdir -p "$fetchmeta_out/compiler-tmp"
    echo "FETCHMETA artifacts: $fetchmeta_out"
    export TMPDIR="$fetchmeta_out/compiler-tmp"
    export VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32
    export VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32
    # The outer cap includes waiting for the shared heavy-build lock. The
    # guard synchronously closes its entire scope before returning, including
    # timeout paths. Never fall back to an unguarded frontend.
    exec timeout --kill-after=10s 540s "$fetchmeta_repo/tools/build_scope.sh" -- \
        bash "$0" --inner "$fetchmeta_out"
fi

[[ "$#" == 2 ]] || exit 2
fetchmeta_out="$2"
case "$fetchmeta_out" in
    /tmp/fetchmeta.*) fetchmeta_suffix="${fetchmeta_out#/tmp/fetchmeta.}" ;;
    "$fetchmeta_repo/verif/tb/obj_dir_fetchmeta_"*)
        fetchmeta_suffix="${fetchmeta_out#"$fetchmeta_repo/verif/tb/obj_dir_fetchmeta_"}" ;;
    *) exit 2 ;;
esac
[[ "$fetchmeta_suffix" =~ ^[A-Za-z0-9_.]+$ && -d "$fetchmeta_out" &&
   "$(stat -c %u -- "$fetchmeta_out")" == "$UID" ]] || exit 2
[[ "$(readlink -f -- "$fetchmeta_out")" == "$fetchmeta_out" ]] || exit 2
[[ "${VENTIUM_BUILD_SCOPE_PROFILE:-}" == ipc_parallel32 &&
   "${VENTIUM_BUILD_SCOPE_UNIT:-}" == ventium-ipc-parallel32 ]] || exit 2
"$fetchmeta_repo/tools/build_scope.sh" --is-active
cd "$fetchmeta_repo"
fetchmeta_sources=(rtl/ventium_pkg.sv rtl/core/ventium_alu_pkg.sv
    rtl/core/ventium_decode_pkg.sv rtl/fpu/fpu_x87_pkg.sv
    rtl/core/ventium_sys_pkg.sv rtl/core/ventium_x87_pkg.sv
    rtl/core/decode_stages.sv verif/fetchmeta/tb_fetchmeta.sv)
sha256sum "${fetchmeta_sources[@]}" verif/fetchmeta/run-fetchmeta-gate.sh \
    tools/verilator_serial.sh tools/build_scope.sh > "$fetchmeta_out/live-sources.sha256"
fetchmeta_frozen=()
for fetchmeta_relative in "${fetchmeta_sources[@]}"; do
    mkdir -p "$fetchmeta_out/src/$(dirname -- "$fetchmeta_relative")"
    cp -p -- "$fetchmeta_relative" "$fetchmeta_out/src/$fetchmeta_relative"
    fetchmeta_frozen+=("$fetchmeta_out/src/$fetchmeta_relative")
done
# sysop_e is deliberately a compilation-unit typedef in core.sv, not a package.
# Use its exact source declaration without elaborating the entire core. Keep
# the complete source snapshot for provenance; only this selected declaration
# is a leaf build input, so independent edits to the core body do not invalidate
# this decoder-only check. A changed typedef still fails the post-run compare.
cp -p rtl/core/core.sv "$fetchmeta_out/src/rtl/core/core.sv"
fetchmeta_sysop_type() {
    awk '
        /^typedef enum logic \[4:0\] \{/ && !capturing {capturing=1}
        capturing {print}
        capturing && /^} sysop_e;$/ {found=1; exit}
        END {if (!found) exit 1}
    ' "$1"
}
fetchmeta_sysop_type "$fetchmeta_out/src/rtl/core/core.sv" > "$fetchmeta_out/sysop_types.sv"
fetchmeta_frozen=("$fetchmeta_out/sysop_types.sv" "${fetchmeta_frozen[@]}")
sha256sum "${fetchmeta_frozen[@]}" "$fetchmeta_out/src/rtl/core/core.sv" \
    > "$fetchmeta_out/frozen-sources.sha256"
systemctl --user show "${VENTIUM_BUILD_SCOPE_UNIT}.scope" \
    --property=MemoryMax --property=TasksMax --property=ControlGroup \
    > "$fetchmeta_out/resource-limits.txt"
"$fetchmeta_repo/tools/verilator_serial.sh" -j32 --binary --timing --assert -sv \
    -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT +define+VTM_NO_DPI \
    --top-module tb_fetchmeta -Mdir "$fetchmeta_out/model" -o test \
    "${fetchmeta_frozen[@]}" > "$fetchmeta_out/build.log" 2>&1 || {
        tail -60 "$fetchmeta_out/build.log"; exit 1;
    }
fetchmeta_native_rc=0
timeout --kill-after=5s 30s "$fetchmeta_out/model/test" \
    > "$fetchmeta_out/run.log" 2>&1 || fetchmeta_native_rc=$?
printf 'native_exit=%s\n' "$fetchmeta_native_rc" > "$fetchmeta_out/native-result.txt"
sha256sum -c "$fetchmeta_out/live-sources.sha256" > "$fetchmeta_out/live-stability.log"
sha256sum -c "$fetchmeta_out/frozen-sources.sha256" > "$fetchmeta_out/frozen-stability.log"
fetchmeta_sysop_type rtl/core/core.sv > "$fetchmeta_out/sysop-types-after.sv"
cmp "$fetchmeta_out/sysop_types.sv" "$fetchmeta_out/sysop-types-after.sv"
sha256sum "$fetchmeta_out/model/test" > "$fetchmeta_out/binary.sha256"
cat "$fetchmeta_out/run.log"
[[ "$fetchmeta_native_rc" == 0 ]] || exit 1
rg -qx 'FETCHMETA-GATE-OK checks=[1-9][0-9]*' "$fetchmeta_out/run.log"
echo "FETCHMETA standalone PASS: $fetchmeta_out"
