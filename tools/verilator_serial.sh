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
# --build/--binary invocation is therefore delegated to build_scope.sh, which
# owns the process-wide lock and runs it in a synchronous user scope with hard
# memory and task limits.  Fail closed if the scope cannot be created; running
# an uncontained generated-C++ build is not an acceptable fallback.
set -euo pipefail

lock_path="${VENTIUM_HEAVY_BUILD_LOCK:-${VENTIUM_VERILATOR_LOCK:-/tmp/ventium-heavy-build.lock}}"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
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

if [ "$is_build" = 1 ] && [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    # Do not take this script's lock before handing off: build_scope.sh owns
    # the same flock for the complete scoped process tree.  A second open
    # descriptor here can self-block while the wrapper is re-execed.
    exec env -u VERILATOR_BIN "${script_dir}/build_scope.sh" -- "${verilator_bin}" "$@"
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

exec env -u VERILATOR_BIN "${verilator_bin}" "$@"
