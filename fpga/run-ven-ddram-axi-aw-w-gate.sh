#!/usr/bin/env bash
# Directed AXI channel-independence regression for the FPGA DDRAM bridge.
# The bridge lives in the external ao486 platform; apply patch 0005 first.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="${VEN_DDRAM_AXI:-/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/src/ven_ddram_axi.v}"
tb="$repo_root/fpga/ven_ddram_axi_aw_w_tb.sv"
tmpdir="$(mktemp -d /tmp/ven_ddram_axi_aw_w.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

if [[ ! -r "$bridge" ]]; then
    echo "DDRAM-AXI-AW-W-GATE FAIL: bridge not readable: $bridge" >&2
    exit 2
fi

iverilog -g2012 -s ven_ddram_axi_aw_w_tb -o "$tmpdir/test.vvp" "$bridge" "$tb"
vvp "$tmpdir/test.vvp"
echo "DDRAM-AXI-AW-W-GATE-OK"
