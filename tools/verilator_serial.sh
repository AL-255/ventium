#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Serialize heavyweight Ventium Verilator invocations across independent terminals.
# A full-core generated C++ translation unit can consume several GiB while g++ is
# optimizing it.  Per-build `-j 1` is necessary but insufficient when a testbench,
# the ao486 cosim, and the shared-FP tests are launched from separate shells.
#
# The lock is advisory and process-owned: a failed, killed, or completed Verilator
# process releases it automatically.  Set VENTIUM_VERILATOR_BIN to select another
# Verilator frontend; do not bypass this wrapper for normal project builds.
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
# VERILATOR_BIN is reserved by Verilator itself for the *compiled backend*
# (normally `verilator_bin`).  Exporting `VERILATOR_BIN=verilator` caused the
# Perl frontend to run itself recursively for every --get-supported probe.  Keep
# the project selector in a distinct namespace and remove the reserved variable
# from the actual frontend's environment.  The old spelling remains an input-only
# compatibility fallback for callers that have not switched yet.
verilator_bin="${VENTIUM_VERILATOR_BIN:-${VERILATOR_BIN:-verilator}}"
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
    # A waited transient service keeps both the launcher and its inherited
    # flock FD alive for the complete generated-code build.  systemd rejects
    # --wait with --scope, so use a service and preserve the caller's CWD.
    exec env -u VERILATOR_BIN systemd-run --user --quiet --wait --collect --working-directory "$PWD" \
        -p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" \
        -- "${verilator_bin}" "$@"
fi

exec env -u VERILATOR_BIN "${verilator_bin}" "$@"
