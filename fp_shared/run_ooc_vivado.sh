#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Non-preemptive launcher for the scratch FP-only OOC syntheses.  A board build
# has priority: unlike fpga/run_vivado_exclusive.sh, this script never signals
# an existing process and never waits behind a lock that may later replace it.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ $# -ne 1 || ( $1 != old && $1 != shared ) ]]; then
    echo "usage: $0 old|shared" >&2
    exit 64
fi

while IFS= read -r process_name; do
    if [[ $process_name == vivado ]]; then
        echo "FP OOC synthesis refused: another Vivado process is active" >&2
        exit 75
    fi
done < <(ps -eo comm=)

exec /tools/Xilinx/2025.2/Vivado/bin/vivado \
    -mode batch -nojournal -nolog \
    -source "$script_dir/synth_xczu15eg.tcl" -tclargs "$1"
