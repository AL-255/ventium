#!/usr/bin/env bash
# Bounded leaf/whole-core diagnostic for the default-off banked L1 data layout.
# No QEMU, BIOS, gameplay, or full verification is run here.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d /tmp/ventium-p54-banked-l1d.XXXXXX)"
echo "Artifacts: $out"

build_run() {
    local top="$1" sets="$2" label="$3"
    shift 3
    local dir="$out/$label"
    local options=(+define+VEN_L1D_BANKED_DATA "$@")
    if [[ "$top" == tb_l1d ]]; then options+=("-GTB_L1_SETS=$sets"); fi
    timeout 90s "$root/tools/verilator_serial.sh" --binary --assert -sv \
        -Wall -Wno-UNUSED -Wno-fatal \
        -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
        -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
        "${options[@]}" --top-module "$top" -Mdir "$dir" \
        "$root/rtl/mem/ven_l1d.sv" "$root/verif/l1/$top.sv" \
        > "$out/$label.build.log" 2>&1 || {
            tail -50 "$out/$label.build.log"
            return 1
        }
    timeout 20s "$dir/V$top" > "$out/$label.run.log" 2>&1 || {
        tail -50 "$out/$label.run.log"
        return 1
    }
    echo "$label: PASS"
}

build_run tb_l1d 128 base_128
build_run tb_l1d 64 base_64
build_run tb_l1d_coherence 128 coherence
build_run tb_l1d_window_reuse 128 window +define+VEN_L1D_WINDOW_REUSE
build_run tb_l1d_hit_stream 128 stream +define+VEN_L1D_HIT_STREAM \
    +define+VEN_L1D_WINDOW_REUSE
echo P54-BANKED-L1D-MICRO-OK
