#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Scratch FP-only OOC synthesis launcher. This MUST use the repository-wide
# Vivado launcher: every new run terminates existing `vivado` processes before
# it starts, so no pair of board/OOC jobs can exhaust memory or corrupt each
# other's timing evidence.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exclusive_launcher="$script_dir/../fpga/run_vivado_exclusive.sh"

if [[ $# -ne 1 || ( $1 != old && $1 != shared ) ]]; then
    echo "usage: $0 old|shared" >&2
    exit 64
fi

[[ -x "$exclusive_launcher" ]] || {
    echo "FP OOC synthesis cannot find Vivado launcher: $exclusive_launcher" >&2
    exit 66
}

exec "$exclusive_launcher" \
    -mode batch -nojournal -nolog \
    -source "$script_dir/synth_xczu15eg.tcl" -tclargs "$1"
