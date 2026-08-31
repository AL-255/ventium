#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Serialize heavyweight Ventium Verilator invocations across independent terminals.
# A full-core generated C++ translation unit can consume several GiB while g++ is
# optimizing it.  Per-build `-j 1` is necessary but insufficient when a testbench,
# the ao486 cosim, and the shared-FP tests are launched from separate shells.
#
# The lock is advisory and process-owned: a failed, killed, or completed Verilator
# process releases it automatically.  Set VERILATOR_BIN to select another Verilator
# binary; do not bypass this wrapper for normal project builds.
set -euo pipefail

lock_path="${VENTIUM_VERILATOR_LOCK:-/tmp/ventium-verilator-build.lock}"
verilator_bin="${VERILATOR_BIN:-verilator}"

if ! command -v flock >/dev/null 2>&1; then
    echo "[verilator-lock] flock unavailable; running without the cross-build lock" >&2
    exec "${verilator_bin}" "$@"
fi

exec 9>"${lock_path}"
if ! flock -n 9; then
    echo "[verilator-lock] another Ventium Verilator build is active; waiting for it to finish" >&2
    flock 9
fi

exec "${verilator_bin}" "$@"
