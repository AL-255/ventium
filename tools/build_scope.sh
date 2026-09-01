#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Run a complete Ventium generated-code build in the same serialized, bounded
# user scope as a normal Verilator --build.  This covers tools such as pipeviz
# which run g++ themselves after Verilator emits C++; wrapping only the
# Verilator front-end would leave those compilers outside the memory boundary.
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

lock_path="${VENTIUM_VERILATOR_LOCK:-/tmp/ventium-verilator-build.lock}"
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
scope_mem="${VENTIUM_VERILATOR_MEMORY_MAX:-6G}"
scope_tasks="${VENTIUM_VERILATOR_TASKS_MAX:-64}"
exec systemd-run --user --scope --quiet \
    -p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" \
    -- "$@"
