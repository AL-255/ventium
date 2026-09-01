#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Run a complete Ventium heavyweight build or verification fan-out in a
# serialized, bounded user scope.  This covers tools such as pipeviz which run
# g++ themselves after Verilator emits C++, as well as gates which fork many
# QEMU/Python workers.  Wrapping only the Verilator front-end leaves both kinds
# of descendants outside the resource boundary.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
    echo "usage: $0 -- command [arg ...]" >&2
    exit 2
fi
shift

# A guarded script re-executes itself inside the scope.  Do not acquire a
# second flock there: the parent keeps FD 9 open for the whole scope lifetime.
if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" = "1" ]; then
    exec "$@"
fi

lock_path="${VENTIUM_HEAVY_BUILD_LOCK:-${VENTIUM_VERILATOR_LOCK:-/tmp/ventium-heavy-build.lock}}"
if ! command -v flock >/dev/null 2>&1; then
    echo "[build-scope] flock is required to serialize generated-code builds" >&2
    exit 125
fi
command -v systemd-run >/dev/null 2>&1 || {
    echo "[build-scope] systemd-run is required to contain generated-code builds" >&2
    exit 125
}

exec 9>"${lock_path}"
if ! flock -n 9; then
    echo "[build-scope] another Ventium generated-code build is active; waiting for it to finish" >&2
    flock 9
fi

export VENTIUM_BUILD_SCOPE_ACTIVE=1
# A parent `make -j` exports its jobserver through MAKEFLAGS into recursive
# make calls.  The scope protects memory, but force those descendants to one
# recipe as well so they fail predictably rather than accumulating thousands of
# short-lived helper processes under the task ceiling.
export MAKEFLAGS="${MAKEFLAGS:+${MAKEFLAGS} }-j1"
scope_mem="${VENTIUM_BUILD_MEMORY_MAX:-${VENTIUM_VERILATOR_MEMORY_MAX:-6G}}"
scope_tasks="${VENTIUM_BUILD_TASKS_MAX:-${VENTIUM_VERILATOR_TASKS_MAX:-64}}"
# Use a transient service, not --scope: systemd rejects --wait for a scope.  A
# waited service makes the wrapper's lock lifetime exactly match the child tree.
exec systemd-run --user --quiet --wait --collect --working-directory "$PWD" \
    -p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" \
    -- "$@"
