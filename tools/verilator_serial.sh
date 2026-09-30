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
# It also caps each Verilator C++ build at one compiler by default. The explicit
# ipc_parallel permits four jobs under 10G; ipc_parallel32 permits 32 with
# finer generated-C++ splitting under 16G. `-j 0`
# means every host core and has repeatedly OOM-killed developer machines when a
# full-core generated translation unit is being optimised.  There is no runtime
# escape hatch: a larger build needs an explicitly reviewed tool/profile change,
# not an environment variable that can accidentally leak into a terminal.
#
# Compiler-job flags alone are not a safety boundary: a 2026-08-31 failure
# spawned thousands of Perl children from a supposedly one-job build.  Every
# nontrivial Verilator invocation is therefore delegated to build_scope.sh,
# which owns the process-wide lock and runs it in a synchronous user scope with
# hard memory and task limits.  This includes --lint-only: elaborating the full
# RTL is expensive even when Verilator does not compile generated C++.  Fail
# closed if the scope cannot be created; running an uncontained elaboration or
# generated-C++ build is not an acceptable fallback.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
# VERILATOR_BIN is reserved by Verilator itself for the *compiled backend*
# (normally `verilator_bin`).  Exporting `VERILATOR_BIN=verilator` caused the
# Perl frontend to run itself recursively for every --get-supported probe.  Keep
# the project selector in a distinct namespace and remove the reserved variable
# from the actual frontend's environment.  The old spelling remains an input-only
# compatibility fallback for callers that have not switched yet.
verilator_bin="${VENTIUM_VERILATOR_BIN:-${VERILATOR_BIN:-verilator}}"

# These probes neither elaborate RTL nor launch a compiler.  Keep them outside
# the heavyweight scope so normal tool discovery remains cheap; everything else
# must enter the verified cgroup below.
is_trivial=0
case "$#:$*" in
    1:--version|1:-V|1:--help) is_trivial=1 ;;
    2:--getenv\ *) is_trivial=1 ;;
esac

# `-MAKEFLAGS` is forwarded verbatim to Verilator's generated GNU makefile.
# Looking only for a whitespace-separated `-j` is not enough: an assignment
# such as `MAKEFLAGS=-j8` reaches GNU make and silently restores parallel
# compilation. Normal builds use the two single-token host optimization
# assignments below. The one exact snapshot fragment is also reviewed: it only
# generates an input header and adds a tb_main.o prerequisite, without recipes
# that launch another compiler pool. The serial LTO bundle below is likewise
# exact and confined to the fixed ipc_parallel32 scope. Keep a whitelist rather than trying to
# blacklist every GNU-make spelling that can create a jobserver or worker pool.
# BEGIN serial LTO flag policy (also exercised independently by unit tests).
serial_lto_cpp_seen=0
serial_lto_ld_seen=0
serial_lto_ar_seen=0
note_serial_lto_makeflag() {
    local makeflags_arg="$1"
    case "$makeflags_arg" in
        USER_CPPFLAGS=-flto=1) serial_lto_cpp_seen=$((serial_lto_cpp_seen + 1)) ;;
        USER_LDFLAGS=-flto=1) serial_lto_ld_seen=$((serial_lto_ld_seen + 1)) ;;
        AR=gcc-ar) serial_lto_ar_seen=$((serial_lto_ar_seen + 1)) ;;
        *flto*)
            echo "[verilator-lock] rejecting unapproved LTO make flag: $makeflags_arg" >&2
            return 1 ;;
        *) return 0 ;;
    esac
    if [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" != "ipc_parallel32" ]; then
        echo "[verilator-lock] serial LTO requires the fixed ipc_parallel32 scope" >&2
        return 1
    fi
}
validate_serial_lto_makeflags() {
    if (( serial_lto_cpp_seen == 0 && serial_lto_ld_seen == 0 && serial_lto_ar_seen == 0 )); then
        return 0
    fi
    if (( serial_lto_cpp_seen != 1 || serial_lto_ld_seen != 1 || serial_lto_ar_seen != 1 )); then
        echo "[verilator-lock] serial LTO requires exactly one compile/link/archive flag bundle" >&2
        return 1
    fi
}
safe_makeflags() {
    local makeflags_arg="$1"
    [[ "$makeflags_arg" =~ ^OPT_FAST=-O(0|1|2|3|g|s|fast)$ ]] && return 0
    [[ "$makeflags_arg" == "-f ${script_dir}/../verif/tb/model_input_snapshot.mk" ]] && return 0
    [[ "$makeflags_arg" == "-f $(cd -- "${script_dir}/../verif/tb" && pwd)/model_input_snapshot.mk" ]] && return 0
    if [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel32" ]; then
        case "$makeflags_arg" in
            USER_CPPFLAGS=-flto=1|USER_LDFLAGS=-flto=1|AR=gcc-ar) return 0 ;;
        esac
    fi
    # OPT carries exactly the one reviewed target-architecture option (today
    # `-march=native`). General LTO flags remain forbidden: they could create
    # an independent worker pool outside Verilator's compiler-job control.
    [[ "$makeflags_arg" =~ ^OPT=-march=[[:alnum:]_.+-]+$ ]]
}
# END serial LTO flag policy.

bounded_build_jobs() {
    local requested="$1"
    if [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel" ] &&
       [[ "$requested" =~ ^[1-4]$ ]]; then
        printf '%s\n' "$requested"
    elif [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel32" ] &&
         [[ "$requested" =~ ^([1-9]|[12][0-9]|3[012])$ ]]; then
        printf '%s\n' "$requested"
    else
        printf '1\n'
    fi
}

safe_args=()
need_build_job=0
need_safe_layout=0
saw_job=0
saw_output_groups=0
saw_output_split=0
saw_output_split_cfuncs=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --build|--binary)
            need_build_job=1
            need_safe_layout=1
            safe_args+=("$1")
            ;;
        --cc)
            # `--cc` may be compiled by a caller (pipeviz is one example),
            # so apply the same generated-C++ layout guard even without
            # Verilator's own --build phase.
            need_safe_layout=1
            safe_args+=("$1")
            ;;
        -j)
            saw_job=1
            shift
            if [ "$#" -eq 0 ]; then
                echo "[verilator-lock] malformed -j argument" >&2
                exit 2
            fi
            safe_args+=("-j" "$(bounded_build_jobs "$1")")
            ;;
        -j[0-9]*)
            saw_job=1
            # Verilator accepts the compact input spelling, but its frontend
            # requires the normalized form as two argv tokens (`-j N`), not
            # GCC-style `-j1`.
            safe_args+=("-j" "$(bounded_build_jobs "${1#-j}")")
            ;;
        --build-jobs|--verilate-jobs)
            saw_job=1
            if [ "$#" -lt 2 ]; then
                echo "[verilator-lock] malformed $1 argument" >&2
                exit 2
            fi
            safe_args+=("$1" "1")
            shift
            ;;
        --build-jobs=*|--verilate-jobs=*)
            saw_job=1
            safe_args+=("${1%%=*}=1")
            ;;
        -MAKEFLAGS)
            if [ "$#" -lt 2 ]; then
                echo "[verilator-lock] malformed -MAKEFLAGS argument" >&2
                exit 2
            fi
            note_serial_lto_makeflag "$2" || exit 2
            if ! safe_makeflags "$2"; then
                echo "[verilator-lock] dropping unapproved generated-make flag: $2" >&2
            else
                safe_args+=("-MAKEFLAGS" "$2")
            fi
            shift
            ;;
        -MAKEFLAGS=*)
            makeflags_arg="${1#-MAKEFLAGS=}"
            note_serial_lto_makeflag "$makeflags_arg" || exit 2
            if ! safe_makeflags "$makeflags_arg"; then
                echo "[verilator-lock] dropping unapproved generated-make flag: $makeflags_arg" >&2
            else
                safe_args+=("$1")
            fi
            ;;
        --output-groups)
            saw_output_groups=1
            if [ "$#" -lt 2 ]; then
                echo "[verilator-lock] malformed --output-groups argument" >&2
                exit 2
            fi
            if [ "$2" != "0" ]; then
                echo "[verilator-lock] forcing --output-groups 0 (requested $2)" >&2
            fi
            safe_args+=("$1" "0")
            shift
            ;;
        --output-groups=*)
            saw_output_groups=1
            if [ "${1#*=}" != "0" ]; then
                echo "[verilator-lock] forcing --output-groups 0 (requested ${1#*=})" >&2
            fi
            safe_args+=("--output-groups" "0")
            ;;
        --output-split|--output-split-cfuncs)
            split_arg="$1"
            if [ "$#" -lt 2 ]; then
                echo "[verilator-lock] malformed ${split_arg} argument" >&2
                exit 2
            fi
            if [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel32" ]; then
                safe_args+=("$split_arg" "3000")
            else
                safe_args+=("$split_arg" "$2")
            fi
            if [ "$split_arg" = "--output-split" ]; then
                saw_output_split=1
            else
                saw_output_split_cfuncs=1
            fi
            shift
            ;;
        --output-split=*|--output-split-cfuncs=*)
            split_arg="${1%%=*}"
            if [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel32" ]; then
                safe_args+=("$split_arg" "3000")
            else
                safe_args+=("$1")
            fi
            if [ "$split_arg" = "--output-split" ]; then
                saw_output_split=1
            else
                saw_output_split_cfuncs=1
            fi
            ;;
        *)
            safe_args+=("$1")
            ;;
    esac
    shift
done
validate_serial_lto_makeflags || exit 2
if [ "$need_build_job" = 1 ] && [ "$saw_job" = 0 ]; then
    safe_args+=("-j" "1")
fi
# A split limit by itself is not a memory bound: Verilator can aggregate all
# fragments back into one V*_vm_classes_0.cpp.  Ungrouped classes are a strict
# guarded policy, just like the one-compiler limit; caller layout overrides
# cannot reintroduce the monolithic OOM failure mode.
if [ "$need_safe_layout" = 1 ] && [ "$saw_output_groups" = 0 ]; then
    safe_args+=("--output-groups" "0")
fi
if [ "$need_safe_layout" = 1 ] &&
   [ "${VENTIUM_BUILD_SCOPE_PROFILE:-default}" = "ipc_parallel32" ]; then
    if [ "$saw_output_split" = 0 ]; then safe_args+=("--output-split" "3000"); fi
    if [ "$saw_output_split_cfuncs" = 0 ]; then safe_args+=("--output-split-cfuncs" "3000"); fi
fi
set -- "${safe_args[@]}"

# Do not trust an inherited marker alone: build_scope.sh verifies the named
# cgroup before permitting a nested call to bypass its lock/cap.  Re-exec this
# wrapper (rather than the frontend directly) so the inner invocation sees the
# verified scope and applies the same argument normalization exactly once.
if [ "$is_trivial" = 0 ] && ! "${script_dir}/build_scope.sh" --is-active; then
    exec env -u VERILATOR_BIN "${script_dir}/build_scope.sh" -- "$0" "$@"
fi

# build_scope's outer lock serializes independent terminals.  A single trusted
# scope can still contain two backgrounded/nested wrapper invocations, though;
# serialize those frontends too.  Acquire this only after the verified scope
# check above, so the outer re-exec cannot hold it while creating the scope.
# The FD survives the final exec and releases automatically if Verilator dies.
if [ "$is_trivial" = 0 ]; then
    invoke_lock="/tmp/ventium-verilator-invoke.lock"
    exec 8>"$invoke_lock"
    if ! flock -n 8; then
        echo "[verilator-lock] another Verilator invocation is active; waiting for it to finish" >&2
        flock 8
    fi
fi

exec env -u VERILATOR_BIN "${verilator_bin}" "$@"
