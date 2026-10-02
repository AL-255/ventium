#!/usr/bin/env bash
# Narrow, host-only checks for the physical 40 MHz clock primitive and the
# external-flow PS/2 injector's clock-rate scaling. This never invokes Vivado.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: fpga/test_clock_rates.sh --injector-source /external/FLOW/src/ven_ps2_kbd_inject.v

The injector source is deliberately required and explicit: fpga/ does not own
the external RK flow, so this gate must not silently test a copied/stale module.
Only a directory under /tmp may be used for temporary outputs.
EOF
    exit 2
}

if [[ $# -ne 2 || $1 != "--injector-source" ]]; then
    usage
fi

injector_source="$2"
if [[ ! -r "$injector_source" ]]; then
    echo "CLOCK-RATES-GATE-FAIL: unreadable external injector source: $injector_source" >&2
    exit 2
fi
injector_source="$(cd "$(dirname "$injector_source")" && pwd -P)/$(basename "$injector_source")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
clock_tb="$script_dir/tb_clk40.sv"
clock_module="$script_dir/clk_div32_40mhz.v"
ps2_tb="$script_dir/tb_ps2_clock_rate.sv"
unisim_src="${VEN_UNISIM_SRC:-/tools/Xilinx/2025.2/Vivado/data/verilog/src}"
unisim_dir="$unisim_src/unisims"
glbl_source="$unisim_src/glbl.v"

for source_item in "$clock_tb" "$clock_module" "$ps2_tb" "$injector_source" "$unisim_dir/MMCME4_BASE.v" "$unisim_dir/MMCME4_ADV.v" "$unisim_dir/BUFG.v" "$unisim_dir/BUFGCE.v" "$glbl_source"; do
    if [[ ! -r "$source_item" ]]; then
        echo "CLOCK-RATES-GATE-FAIL: required source is unreadable: $source_item" >&2
        exit 2
    fi
done

for tool_item in iverilog vvp timeout sha256sum; do
    if ! command -v "$tool_item" >/dev/null 2>&1; then
        echo "CLOCK-RATES-GATE-FAIL: required tool is unavailable: $tool_item" >&2
        exit 2
    fi
done

tmp_base="${TMPDIR:-/tmp}"
case "$tmp_base" in
    /tmp|/tmp/*) ;;
    *)
        echo "CLOCK-RATES-GATE-FAIL: TMPDIR must be /tmp or below it, got: $tmp_base" >&2
        exit 2
        ;;
esac
if [[ ! -d "$tmp_base" ]]; then
    echo "CLOCK-RATES-GATE-FAIL: TMPDIR does not exist: $tmp_base" >&2
    exit 2
fi
tmpdir="$(mktemp -d "$tmp_base/ventium-clock-rates.XXXXXX")"
cleanup() {
    # Only these two generated files belong to the test. Never recursively
    # remove an environment-supplied path or unexpected artifact.
    rm -f -- "$tmpdir/clock40.vvp" "$tmpdir/ps2-rate.vvp"
    rmdir -- "$tmpdir"
}
trap cleanup EXIT

run_bounded() {
    local label="$1"
    shift
    echo "CLOCK-RATES: running $label (50 s maximum)"
    timeout --foreground --kill-after=5s 50s "$@"
    echo "CLOCK-RATES: $label complete"
}

# Genuine Vivado Unisim behavioural primitives are compiled by Icarus; the
# testbench itself contains the clock absence/lock/period assertions.
run_bounded "40 MHz MMCM primitive" \
    bash -euo pipefail -c '
        iverilog -g2012 -s tb_clock40 -s glbl -o "$1" \
            "$2" "$3" "$4" "$5" "$6" "$7" "$8"
        vvp "$1"
    ' bash \
    "$tmpdir/clock40.vvp" "$clock_tb" "$clock_module" \
    "$unisim_dir/MMCME4_BASE.v" "$unisim_dir/MMCME4_ADV.v" \
    "$unisim_dir/BUFG.v" "$unisim_dir/BUFGCE.v" "$glbl_source"

# This source is the explicit external FLOW injector, rather than a local
# duplicate. The testbench checks both default 3.125 MHz and scaled 40 MHz.
run_bounded "PS/2 injector clock rates" \
    bash -euo pipefail -c '
        iverilog -g2012 -s tb_ps2_rate -o "$1" "$2" "$3"
        vvp "$1"
    ' bash \
    "$tmpdir/ps2-rate.vvp" "$ps2_tb" "$injector_source"

injector_sha="$(sha256sum "$injector_source" | awk '{print $1}')"
echo "CLOCK-RATES-GATE-OK injector=$injector_source sha256=$injector_sha"
