#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Run a complete Ventium heavyweight build or verification fan-out in a
# serialized, bounded user scope.  This covers tools such as pipeviz which run
# g++ themselves after Verilator emits C++, as well as gates which fork many
# QEMU/Python workers.  Wrapping only the Verilator front-end leaves both kinds
# of descendants outside the resource boundary.
set -euo pipefail

# The normal verification profile is deliberately fixed.  A generic environment
# variable must not be able to turn a safe terminal command into an unbounded
# generated-C++ build.  Vivado is the one reviewed exception and has its own
# explicit profile below.
normal_memory_max="4G"
normal_tasks_max="64"
# Explicit four-compiler IPC development scope. The normal 4G/one-job profile
# remains unchanged; this larger cap is available only under one named unit.
ipc_parallel_memory_max="10G"
ipc_parallel_tasks_max="64"
# Finer generated-C++ splitting permits a larger, still bounded compile fanout.
# Keep this distinct from the four-job profile so ordinary builds cannot inherit
# a machine-wide -j32 or bypass the fixed process/memory envelope.
ipc_parallel32_memory_max="16G"
ipc_parallel32_tasks_max="128"
vivado_memory_max="20G"
# `general.maxThreads=1` / one `launch_runs -jobs 1` bound synth work, but
# Vivado also creates bounded control, board-repository, and Taskflow helper
# threads.  A 32-TID cgroup cap denied that fixed one-worker family mid-startup.
# Keep a fixed, non-environment-overridable cushion rather than permitting an
# unreviewed task limit; 48 remains below the normal generated-build cap.
vivado_tasks_max="48"
# Keep swap bounded separately from resident memory.  Vivado can retain a large
# working set during synthesis, but allowing an unbounded swap backlog turns an
# OOM into hours of host-wide thrashing.  A caller may request a *smaller* cap
# for an especially constrained run; it may never raise this reviewed ceiling.
vivado_swap_max="2G"
# One fixed lock is part of the safety boundary.  Permitting a caller to choose
# another path creates two independently valid locks and lets heavyweight trees
# overlap again.  It is advisory only for unrelated projects; every Ventium
# guarded entry point deliberately shares this exact file.
lock_path="/tmp/ventium-heavy-build.lock"
# Unlike the advisory lock, an unconfirmed scope cleanup needs a persistent
# fail-closed fence.  Keep its tiny private markers in one fixed location so a
# later guarded invocation can reap the prior scope before it starts another
# generated-code tree.
scope_marker_root="/tmp/ventium-build-scope"
cleanup_retry_count=3

size_to_bytes() {
    local value="$1" magnitude multiplier=1
    if [[ "$value" =~ ^([0-9]+)([KMGTP]?)$ ]]; then
        magnitude="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            "") multiplier=1 ;;
            K) multiplier=$((1024)) ;;
            M) multiplier=$((1024 * 1024)) ;;
            G) multiplier=$((1024 * 1024 * 1024)) ;;
            T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
            P) multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
        esac
        printf '%s\n' "$((magnitude * multiplier))"
        return 0
    fi
    return 1
}

# `size_to_bytes` is appropriate for the fixed, reviewed caps below, but do
# not use shell arithmetic to validate an arbitrary environment value: an
# enormous decimal magnitude could wrap before it is compared.  The Vivado
# ceilings are deliberately expressed in GiB, so compare the decimal
# magnitude against the corresponding exact count in each accepted unit.
# Return 0 for an in-range positive size, 1 for malformed input, 2 for zero,
# and 3 for a positive value above the ceiling.
vivado_size_status() {
    local requested="$1" ceiling_gib="$2" digits unit limit

    [[ "$requested" =~ ^0+([KMGTP]?)$ ]] && return 2
    [[ "$requested" =~ ^([1-9][0-9]*)([KMGTP]?)$ ]] || return 1
    digits="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"

    case "$unit" in
        "") limit=$(( ceiling_gib * 1024 * 1024 * 1024 )) ;;
        K)  limit=$(( ceiling_gib * 1024 * 1024 )) ;;
        M)  limit=$(( ceiling_gib * 1024 )) ;;
        G)  limit="$ceiling_gib" ;;
        T|P) return 3 ;;
    esac

    # Both operands are decimal strings.  Compare their lengths first so no
    # untrusted magnitude enters bash arithmetic; equal-length digit strings
    # compare lexically in numeric order.
    if [ "${#digits}" -lt "${#limit}" ] || \
       { [ "${#digits}" -eq "${#limit}" ] && [[ "$digits" < "$limit" || "$digits" == "$limit" ]]; }; then
        return 0
    fi
    return 3
}

# Return the effective Vivado resident-memory cap.  The public override is
# deliberately one-way: a valid positive value can lower the reviewed 20 GiB
# ceiling, while an attempted increase is explicitly clamped rather than
# silently expanding the scope.  Malformed and zero values are errors because
# interpreting either as an unlimited cgroup would defeat the safety boundary.
vivado_memory_limit() {
    local requested="${VENTIUM_VIVADO_MEMORY_MAX:-$vivado_memory_max}"
    local size_status

    if vivado_size_status "$requested" 20; then
        printf '%s\n' "$requested"
        return 0
    else
        size_status=$?
    fi
    if [ "$size_status" -eq 1 ]; then
        echo "[build-scope] invalid VENTIUM_VIVADO_MEMORY_MAX: ${requested@Q}" >&2
        return 1
    fi
    if [ "$size_status" -eq 2 ]; then
        echo "[build-scope] VENTIUM_VIVADO_MEMORY_MAX must be positive: ${requested@Q}" >&2
        return 1
    fi
    echo "[build-scope] clamping Vivado MemoryMax ${requested@Q} to reviewed ceiling ${vivado_memory_max}" >&2
    printf '%s\n' "$vivado_memory_max"
}

# Swap follows the same non-expanding policy, except zero is meaningful: it
# explicitly disables swap.  Keeping the parser shared with MemoryMax accepts
# only unambiguous binary-unit sizes and makes an oversized request visibly
# clamp to the 2 GiB Vivado ceiling.
vivado_swap_limit() {
    local requested="${VENTIUM_VIVADO_MEMORY_SWAP_MAX:-$vivado_swap_max}"
    local size_status

    if [ "$requested" = "0" ]; then
        printf '%s\n' "$requested"
        return 0
    fi
    if vivado_size_status "$requested" 2; then
        printf '%s\n' "$requested"
        return 0
    else
        size_status=$?
    fi
    if [ "$size_status" -eq 1 ]; then
        echo "[build-scope] invalid VENTIUM_VIVADO_MEMORY_SWAP_MAX: ${requested@Q}" >&2
        return 1
    fi
    if [ "$size_status" -eq 2 ]; then
        # Unit-suffixed zero is normalized too, so systemd always receives its
        # canonical explicit swap-disable spelling.
        printf '%s\n' 0
        return 0
    fi
    echo "[build-scope] clamping Vivado MemorySwapMax ${requested@Q} to reviewed ceiling ${vivado_swap_max}" >&2
    printf '%s\n' "$vivado_swap_max"
}

scope_has_cap() {
    local cgroup_path="$1" memory_cap="$2" tasks_cap="$3" swap_cap="${4:-}"
    local cgroup_root="/sys/fs/cgroup${cgroup_path}"
    local actual_memory actual_tasks actual_swap limit_memory limit_swap

    [ -r "$cgroup_root/memory.max" ] || return 1
    [ -r "$cgroup_root/pids.max" ] || return 1
    actual_memory="$(<"$cgroup_root/memory.max")"
    actual_tasks="$(<"$cgroup_root/pids.max")"
    limit_memory="$(size_to_bytes "$memory_cap")" || return 1
    [[ "$actual_memory" =~ ^[0-9]+$ ]] || return 1
    [[ "$actual_tasks" =~ ^[0-9]+$ ]] || return 1
    (( actual_memory <= limit_memory && actual_tasks <= tasks_cap )) || return 1
    if [ -n "$swap_cap" ]; then
        [ -r "$cgroup_root/memory.swap.max" ] || return 1
        actual_swap="$(<"$cgroup_root/memory.swap.max")"
        limit_swap="$(size_to_bytes "$swap_cap")" || return 1
        [[ "$actual_swap" =~ ^[0-9]+$ ]] || return 1
        (( actual_swap <= limit_swap )) || return 1
    fi
    return 0
}

scope_required_limits() {
    local unit="$1" selected_memory selected_swap
    if [ "$unit" = "ventium-vivado" ]; then
        selected_memory="$(vivado_memory_limit)" || return 1
        selected_swap="$(vivado_swap_limit)" || return 1
        printf '%s %s %s\n' "$selected_memory" "$vivado_tasks_max" "$selected_swap"
    elif [ "$unit" = "ventium-ipc-parallel" ]; then
        printf '%s %s\n' "$ipc_parallel_memory_max" "$ipc_parallel_tasks_max"
    elif [ "$unit" = "ventium-ipc-parallel32" ]; then
        printf '%s %s\n' "$ipc_parallel32_memory_max" "$ipc_parallel32_tasks_max"
    else
        printf '%s %s\n' "$normal_memory_max" "$normal_tasks_max"
    fi
}

# A named, capped cgroup is necessary but not sufficient evidence that the
# caller is inside the serialized build tree: a hand-created `ventium-*` scope
# could otherwise export the active marker and let a second tree bypass the
# global lock.  The real launcher passes its locked FD through systemd-run; a
# reviewed caller using `flock LOCK command` does too.  Verify the actual FD,
# and take an unlocked inherited FD atomically before accepting the scope.
scope_holds_lock() {
    local fd fd_num target
    [ -d /proc/self/fd ] || return 1
    for fd in /proc/self/fd/*; do
        [ -e "$fd" ] || [ -L "$fd" ] || continue
        target="$(readlink -f -- "$fd" 2>/dev/null || true)"
        [ "$target" = "$lock_path" ] || continue
        fd_num="${fd##*/}"
        if flock -n "$fd_num"; then
            return 0
        fi
    done
    return 1
}

# A marker in an inherited environment is not a resource boundary.  Only trust
# it when this process is physically inside the named scope created below.  In
# particular, this prevents `VENTIUM_BUILD_SCOPE_ACTIVE=1` in a terminal or
# make environment from bypassing the global lock and the cgroup limits.
scope_is_active() {
    local unit="${VENTIUM_BUILD_SCOPE_UNIT:-}"
    local _hierarchy _controllers cgroup_path required_memory required_tasks required_swap required_limits

    [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" = "1" ] || return 1
    # Unit names are supplied to systemd-run without a suffix. A project prefix
    # prevents an arbitrary ancestor unit from being accepted as a Ventium
    # containment boundary. The normal launcher uses a transient scope with
    # synchronous whole-cgroup cleanup; retain .service recognition for an
    # existing reviewed remote launcher. Both forms require limits and the
    # inherited lock below.
    [[ "${unit}" =~ ^ventium-[A-Za-z0-9_.@:-]+$ ]] || return 1
    [[ "${unit}" != *.scope ]] || return 1
    [ -r /proc/self/cgroup ] || return 1

    # cgroup v2 reports `0::/…/unit.scope` or `unit.service`. Match a complete
    # path component, not a substring (for example `ventium-build-1` must not
    # match `ventium-build-10`).
    required_limits="$(scope_required_limits "$unit")" || return 1
    read -r required_memory required_tasks required_swap <<< "$required_limits"
    [ -n "$required_memory" ] && [ -n "$required_tasks" ] || return 1
    while IFS=: read -r _hierarchy _controllers cgroup_path; do
        case "/${cgroup_path}/" in
            *"/${unit}.scope/"*|*"/${unit}.service/"*)
                # Merely occupying a similarly named scope is insufficient:
                # verify both the cgroup's leaf limits and ownership of the
                # fixed process-wide lock before allowing a nested invocation
                # to skip the lock/cap setup.
                scope_has_cap "$cgroup_path" "$required_memory" "$required_tasks" "$required_swap" || return 1
                scope_holds_lock || return 1
                return 0
                ;;
        esac
    done < /proc/self/cgroup
    return 1
}

remove_scope_marker_dir() {
  local marker_dir="$1"

    # Marker directories are created with mktemp below, under the fixed
    # private root.  Never recurse here: if an unexpected file appears, leave
    # the directory for the next launch to treat conservatively.
    rm -f -- "${marker_dir}/started" "${marker_dir}/result" "${marker_dir}/unit" 2>/dev/null || true
    rmdir -- "${marker_dir}" 2>/dev/null || true
}

scope_stop_confirmed() {
    local unit="$1" state

    # A normal `stop` waits for the KillMode=control-group job to complete.
    # With --collect, however, systemd can reap an already-empty scope between
    # systemd-run returning and this cleanup call; `stop` then reports "not
    # loaded" even though the manager can still authoritatively report it
    # inactive.  Treat only that confirmed inactive state as safe.  A denied
    # or unavailable user bus makes both queries fail and therefore leaves the
    # persistent fence in place.
    if systemctl --user stop "${unit}.scope" >/dev/null 2>&1; then
        return 0
    fi
    state="$(systemctl --user show "${unit}.scope" --property=ActiveState --value 2>/dev/null)" || return 1
    [ "${state}" = "inactive" ]
}

recover_pending_scopes() {
    local marker_dir marker_unit

    for marker_dir in "${scope_marker_root}"/*; do
        [ -d "${marker_dir}" ] || continue
        [ -f "${marker_dir}/unit" ] || continue
        IFS= read -r marker_unit < "${marker_dir}/unit" || {
            echo "[build-scope] malformed pending scope marker: ${marker_dir}" >&2
            return 1
        }
        if ! [[ "${marker_unit}" =~ ^ventium-[A-Za-z0-9_.@:-]+$ ]] || [[ "${marker_unit}" = *.scope ]]; then
            echo "[build-scope] invalid pending scope marker: ${marker_dir}" >&2
            return 1
        fi

        # A systemd-run launch that never reached its child cannot have left a
        # detached descendant.  This is the normal sandbox-denied-bus case;
        # discard only that marker and let the caller receive systemd-run's
        # original launch failure rather than hanging forever in cleanup.
        if [ ! -e "${marker_dir}/started" ]; then
            remove_scope_marker_dir "${marker_dir}"
            continue
        fi

        # A started marker means code really entered the capped scope.  Do not
        # start a new heavyweight tree until systemd has synchronously stopped
        # that old cgroup.  This persistent fence keeps the serialization
        # guarantee even if the original parent had to return an error.
        if ! scope_stop_confirmed "${marker_unit}"; then
            echo "[build-scope] prior scope ${marker_unit}.scope is not confirmed stopped; refusing a new build" >&2
            return 1
        fi
        remove_scope_marker_dir "${marker_dir}"
    done
}

if [ "${1:-}" = "--is-active" ]; then
    if [ "$#" -ne 1 ]; then
        echo "usage: $0 --is-active" >&2
        exit 2
    fi
    scope_is_active
    exit $?
fi

if [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
    echo "usage: $0 -- command [arg ...]" >&2
    exit 2
fi
shift

# A guarded script re-executes itself inside the scope.  Do not acquire a
# second flock there: the parent keeps FD 9 open for the whole scope lifetime.
if scope_is_active; then
    exec "$@"
fi

# Do not inherit a forged/stale active marker or its unit name into a new
# scope.  A caller may still intentionally select a unit (for example the
# exclusive Vivado launcher) when it has not claimed to be active already.
if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" = "1" ]; then
    echo "[build-scope] ignoring inactive VENTIUM_BUILD_SCOPE_ACTIVE marker" >&2
    unset VENTIUM_BUILD_SCOPE_ACTIVE VENTIUM_BUILD_SCOPE_UNIT
fi

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
command -v systemctl >/dev/null 2>&1 || {
    echo "[build-scope] systemctl is required to reap generated-code builds" >&2
    exit 125
}

exec 9>"${lock_path}"
if ! flock -n 9; then
    echo "[build-scope] another Ventium generated-code build is active; waiting for it to finish" >&2
    flock 9
fi

mkdir -p "${scope_marker_root}"
if ! recover_pending_scopes; then
    exit 125
fi

# A parent `make -j` exports a jobserver token in MAKEFLAGS.  Do not preserve
# it: recursive makes can otherwise reconnect to the parent jobserver and
# silently re-enable parallelism.
export MAKEFLAGS="-j1"
# This host mounts /tmp with a per-user quota.  Generated C++ and compiler
# temporaries used by an RTL build can exceed it despite `df` reporting free
# tmpfs capacity, so keep the project default on the repository volume.  An
# explicit caller choice remains authoritative.
if [ -z "${TMPDIR:-}" ]; then
    export TMPDIR="${VENTIUM_BUILD_TMPDIR:-${repo_root}/tmp/build-tmp}"
    mkdir -p "${TMPDIR}"
fi
# Give every outer entry a named scope and export its stem to descendants.  The
# name is both the nesting proof above and a useful target for post-mortem
# resource inspection.  A caller that owns a long-lived vendor process tree can
# still select a stable project-prefixed name (the exclusive Vivado launcher
# uses `ventium-vivado`).
scope_unit="${VENTIUM_BUILD_SCOPE_UNIT:-ventium-build-${UID}-${BASHPID}-${RANDOM}}"
if ! [[ "${scope_unit}" =~ ^ventium-[A-Za-z0-9_.@:-]+$ ]] || [[ "${scope_unit}" = *.scope ]]; then
    echo "[build-scope] invalid scope unit name: ${scope_unit}" >&2
    exit 2
fi
# Only the exclusive Vivado launcher may use the larger reviewed profile.  The
# ordinary profile ignores stale/malicious generic limit variables rather than
# expanding a build's budget.  Keep both profiles fixed so `--is-active` can
# verify their cgroup limits without trusting inherited configuration.
scope_profile="${VENTIUM_BUILD_SCOPE_PROFILE:-default}"
scope_swap=""
case "$scope_profile" in
    default|"")
        if [ "$scope_unit" = "ventium-vivado" ] || [ "$scope_unit" = "ventium-ipc-parallel" ] || \
           [ "$scope_unit" = "ventium-ipc-parallel32" ]; then
            echo "[build-scope] scope unit ${scope_unit} is reserved for its explicit profile" >&2
            exit 2
        fi
        if [ "${VENTIUM_BUILD_MEMORY_MAX:-$normal_memory_max}" != "$normal_memory_max" ] || \
           [ "${VENTIUM_BUILD_TASKS_MAX:-$normal_tasks_max}" != "$normal_tasks_max" ]; then
            echo "[build-scope] forcing normal profile (${normal_memory_max}, ${normal_tasks_max} tasks)" >&2
        fi
        scope_mem="$normal_memory_max"
        scope_tasks="$normal_tasks_max"
        ;;
    ipc_parallel)
        if [ "$scope_unit" != "ventium-ipc-parallel" ]; then
            echo "[build-scope] ipc_parallel profile requires unit ventium-ipc-parallel" >&2
            exit 2
        fi
        scope_mem="$ipc_parallel_memory_max"
        scope_tasks="$ipc_parallel_tasks_max"
        ;;
    ipc_parallel32)
        if [ "$scope_unit" != "ventium-ipc-parallel32" ]; then
            echo "[build-scope] ipc_parallel32 profile requires unit ventium-ipc-parallel32" >&2
            exit 2
        fi
        scope_mem="$ipc_parallel32_memory_max"
        scope_tasks="$ipc_parallel32_tasks_max"
        ;;
    vivado)
        if [ "$scope_unit" != "ventium-vivado" ]; then
            echo "[build-scope] vivado profile requires scope unit ventium-vivado" >&2
            exit 2
        fi
        scope_mem="$(vivado_memory_limit)" || exit 2
        scope_swap="$(vivado_swap_limit)" || exit 2
        if [ "${VENTIUM_VIVADO_TASKS_MAX:-$vivado_tasks_max}" != "$vivado_tasks_max" ]; then
            echo "[build-scope] forcing reviewed Vivado TasksMax=${vivado_tasks_max}" >&2
        fi
        scope_tasks="$vivado_tasks_max"
        echo "[build-scope] Vivado limits: MemoryMax=${scope_mem} (ceiling ${vivado_memory_max}), MemorySwapMax=${scope_swap} (ceiling ${vivado_swap_max}), TasksMax=${scope_tasks}" >&2
        ;;
    *)
        echo "[build-scope] unknown build profile: $scope_profile" >&2
        exit 2
        ;;
esac
export VENTIUM_BUILD_SCOPE_ACTIVE=1
export VENTIUM_BUILD_SCOPE_UNIT="${scope_unit}"
export VENTIUM_BUILD_SCOPE_PROFILE="${scope_profile}"
scope_args=(--user --scope --quiet --unit="${scope_unit}" --collect)
scope_marker_dir="$(mktemp -d "${scope_marker_root}/${scope_unit}.XXXXXX")"
scope_started_marker="${scope_marker_dir}/started"
scope_result_marker="${scope_marker_dir}/result"
printf '%s\n' "${scope_unit}" > "${scope_marker_dir}/unit"
# `--scope` intentionally keeps the caller's environment, working directory,
# and inherited lock FD.  It returns after scope *creation*, not process
# completion, and `--wait` is invalid with `--scope`.  The in-scope launcher
# therefore records its child's final exit status; the parent polls that
# private marker before releasing FD 9.  Without this handoff, the old EXIT
# cleanup stopped successful long-running gates mid-build and reported the
# launch status as success.
scope_cleanup_done=0
scope_cleanup_failed=0
scope_cleanup() {
    local attempts=0

    # A failed stop is not benign: this parent is the only holder of FD 9, so
    # returning from the EXIT trap would let another heavyweight build start
    # while a detached compiler can still be alive in this scope.  The child
    # creates `started` only after it entered the scope.  If it does not exist,
    # systemd-run could not have launched the requested command (notably a
    # sandbox-denied user bus), so no descendant needs reaping.
    [ "${scope_cleanup_done}" -eq 0 ] || return 0
    trap '' HUP INT TERM
    if [ ! -e "${scope_started_marker}" ]; then
        remove_scope_marker_dir "${scope_marker_dir}"
        scope_cleanup_done=1
        return 0
    fi

    # `stop` is synchronous (we never pass --no-block).  A tiny fixed retry
    # window handles a transient manager hiccup without making denied-bus
    # sandbox calls hang forever.  If all retries fail, leave the marker as a
    # persistent fence; recover_pending_scopes will refuse every later build
    # until that scope is demonstrably stopped.
    while [ "${attempts}" -lt "${cleanup_retry_count}" ]; do
        attempts=$((attempts + 1))
        if scope_stop_confirmed "${scope_unit}"; then
            remove_scope_marker_dir "${scope_marker_dir}"
            scope_cleanup_done=1
            return 0
        fi
        if [ "${attempts}" -lt "${cleanup_retry_count}" ]; then
            sleep 1
        fi
    done
    scope_cleanup_failed=1
    scope_cleanup_done=1
    echo "[build-scope] could not confirm ${scope_unit}.scope stopped; leaving a safety marker and returning 125" >&2
    return 0
}
trap scope_cleanup EXIT HUP INT TERM

wait_for_scope_result() {
    local state result

    while [ ! -s "${scope_result_marker}" ]; do
        # If the cgroup died before its wrapper wrote a status, retain the
        # fail-closed behaviour: callers must not treat an unknown child state
        # as a green verification result.
        state="$(systemctl --user show "${scope_unit}.scope" --property=ActiveState --value 2>/dev/null || true)"
        if [ "${state}" = "inactive" ] || [ -z "${state}" ]; then
            echo "[build-scope] ${scope_unit}.scope ended without a result marker" >&2
            return 1
        fi
        sleep 0.2
    done

    IFS= read -r result < "${scope_result_marker}" || return 1
    if ! [[ "${result}" =~ ^[0-9]+$ ]]; then
        echo "[build-scope] malformed result marker for ${scope_unit}: ${result@Q}" >&2
        return 1
    fi
    printf '%s\n' "${result}"
}

set +e
# The caller's argv is already shell-tokenized. A second expansion by systemd
# would rewrite literal ${name} expressions inside bash -c scripts (including
# variables those scripts have not assigned yet), corrupting paths/arguments.
scope_properties=(-p "MemoryMax=${scope_mem}" -p "TasksMax=${scope_tasks}" -p "KillMode=control-group")
if [ -n "${scope_swap}" ]; then
    scope_properties+=(-p "MemorySwapMax=${scope_swap}")
fi
systemd-run --expand-environment=no "${scope_args[@]}" "${scope_properties[@]}" \
    -- bash -c '
        : > "$1"
        result_file="$2"
        shift 2
        "$@"
        child_status=$?
        printf "%s\\n" "$child_status" > "$result_file"
        exit "$child_status"
    ' build-scope-child "${scope_started_marker}" "${scope_result_marker}" "$@"
launch_status=$?
set -e
if [ "${launch_status}" -ne 0 ]; then
    run_status="${launch_status}"
elif ! run_status="$(wait_for_scope_result)"; then
    run_status=125
fi
scope_cleanup
trap - EXIT HUP INT TERM
if [ "${scope_cleanup_failed}" -ne 0 ]; then
    exit 125
fi
exit "$run_status"
