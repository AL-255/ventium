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
#
# It also caps each Verilator C++ build at one compiler by default.  `-j 0`
# means every host core and has repeatedly OOM-killed developer machines when a
# full-core generated translation unit is being optimised.  A deliberately
# provisioned CI run may set VENTIUM_ALLOW_PARALLEL_VERILATOR=1; it remains
# serialized against other Ventium Verilator builds.
#
# Compiler-job flags alone are not a safety boundary: a 2026-08-31 failure
# spawned thousands of Perl children from a supposedly one-job build.  Every
# --build/--binary invocation is therefore put in a transient user scope with
# a hard memory and task limit.  Fail closed if the scope cannot be created;
# running an uncontained generated-C++ build is not an acceptable fallback.
set -euo pipefail

lock_path="${VENTIUM_HEAVY_BUILD_LOCK:-${VENTIUM_VERILATOR_LOCK:-/tmp/ventium-heavy-build.lock}}"
verilator_bin="${VERILATOR_BIN:-verilator}"
is_build=0
for arg in "$@"; do
    case "$arg" in
        --build|--binary) is_build=1 ;;
    esac
done

if [ "${VENTIUM_ALLOW_PARALLEL_VERILATOR:-0}" != "1" ]; then
    safe_args=()
    need_build_job=0
    saw_job=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --build|--binary)
                need_build_job=1
                safe_args+=("$1")
                ;;
            -j)
                saw_job=1
                safe_args+=("-j" "1")
                shift
                if [ "$#" -eq 0 ]; then
                    echo "[verilator-lock] malformed -j argument" >&2
                    exit 2
                fi
                ;;
            -j[0-9]*)
                saw_job=1
                safe_args+=("-j1")
                ;;
            *)
                safe_args+=("$1")
                ;;
        esac
        shift
    done
    if [ "$need_build_job" = 1 ] && [ "$saw_job" = 0 ]; then
        safe_args+=("-j" "1")
    fi
    set -- "${safe_args[@]}"
fi

if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${lock_path}"
        if ! flock -n 9; then
            echo "[verilator-lock] another Ventium Verilator build is active; waiting for it to finish" >&2
            flock 9
        fi
    else
        echo "[verilator-lock] flock unavailable; cross-build serialization disabled" >&2
    fi
fi

if [ "$is_build" = 1 ] && [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    command -v systemd-run >/dev/null 2>&1 || {
        echo "[verilator-lock] systemd-run is required to contain Verilator builds" >&2
        exit 125
    }
    scope_mem="${VENTIUM_BUILD_MEMORY_MAX:-${VENTIUM_VERILATOR_MEMORY_MAX:-6G}}"
    scope_tasks="${VENTIUM_BUILD_TASKS_MAX:-${VENTIUM_VERILATOR_TASKS_MAX:-64}}"
    # --scope runs the child in a transient cgroup; the inherited lock FD stays
    # live until Verilator and its generated make/cc1plus descendants exit.
    exec systemd-run --user --scope --quiet \
        -p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" \
        -- "${verilator_bin}" "$@"
fi

exec "${verilator_bin}" "$@"
