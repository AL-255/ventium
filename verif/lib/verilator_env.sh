#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Source after setting ROOT in a verification shell script.  Keep direct
# `verilator` calls behind the repository-wide lock and safe one-compiler cap.
# VENTIUM_ALLOW_PARALLEL_VERILATOR=1 is an explicit, provisioned-CI-only escape
# hatch; it retains the cross-build lock.

: "${ROOT:?set ROOT before sourcing verilator_env.sh}"
export VERILATOR_BIN="${VERILATOR_BIN:-verilator}"
verilator() {
    "$ROOT/tools/verilator_serial.sh" "$@"
}
