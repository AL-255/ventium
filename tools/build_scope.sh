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
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
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

# A parent `make -j` exports a jobserver token in MAKEFLAGS.  Do not preserve
# it: recursive makes can otherwise reconnect to the parent jobserver and
# silently re-enable parallelism.
export VENTIUM_BUILD_SCOPE_ACTIVE=1
export MAKEFLAGS="-j1"
# This host mounts /tmp with a per-user quota.  Generated C++ and compiler
# temporaries used by an RTL build can exceed it despite `df` reporting free
# tmpfs capacity, so keep the project default on the repository volume.  An
# explicit caller choice remains authoritative.
if [ -z "${TMPDIR:-}" ]; then
    export TMPDIR="${VENTIUM_BUILD_TMPDIR:-${repo_root}/tmp/build-tmp}"
    mkdir -p "${TMPDIR}"
fi
scope_mem="${VENTIUM_BUILD_MEMORY_MAX:-${VENTIUM_VERILATOR_MEMORY_MAX:-6G}}"
scope_tasks="${VENTIUM_BUILD_TASKS_MAX:-${VENTIUM_VERILATOR_TASKS_MAX:-64}}"
# A synchronous scope runs the command as our child in a bounded cgroup.  That
# is essential here: unlike a transient service, it retains the caller's PATH,
# TB_BIN, cache locations, and the active-scope guard.  systemd-run waits for a
# scope command by default, so FD 9 keeps the global build lock until its whole
# process tree exits.
exec systemd-run --user --scope --quiet \
    -p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" \
    -- "$@"
