#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Run one *top-level* Ventium Vivado build at a time.
#
# What must never coexist is a second Vivado process family: two runs can
# consume the entire host, swap heavily, and make both results untrustworthy.
# This launcher deliberately has host-global semantics.  Each new invocation
# stops the named cgroup from the preceding guarded run, then finds every
# remaining executable from the Vivado installation and its descendants.  That
# includes VRS/task helpers whose executable name is not literally "vivado".
#
# Do not invoke `vivado -mode batch ...` directly for this project.  Use:
#   fpga/run_vivado_exclusive.sh -mode batch -source ... -tclargs ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if (( $# == 0 )); then
    echo "usage: $0 <Vivado arguments>" >&2
    exit 64
fi

lock_dir="${VENTIUM_VIVADO_LOCK_DIR:-${SCRIPT_DIR}/../tmp}"
mkdir -p "$lock_dir"
lock_file="${lock_dir}/ventium-vivado-exclusive.lock"
terminate_timeout=45
vivado_scope="ventium-vivado.scope"
vivado_install="$(readlink -f "${VENTIUM_VIVADO_ROOT:-/tools/Xilinx/2025.2/Vivado}")"
vivado_uid="$(id -u)"

proc_ppid() {
    local stat
    local fields

    [[ -r "/proc/$1/stat" ]] || return 1
    IFS= read -r stat < "/proc/$1/stat" || return 1
    # The second field is parenthesized and may contain spaces, so remove it
    # before selecting field four (the parent PID) from the remaining words.
    fields="${stat##*) }"
    set -- $fields
    (( $# >= 2 )) || return 1
    printf "%s\n" "$2"
}

vivado_seed_pids() {
    local proc
    local pid
    local uid
    local exe

    # Only consider our own executables below the configured Vivado tree.  A
    # shell argument or an unrelated same-name program cannot match this test.
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        [[ "$pid" != "$$" ]] || continue
        uid="$(stat -c "%u" "$proc" 2>/dev/null || true)"
        [[ "$uid" == "$vivado_uid" ]] || continue
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        case "$exe" in
            "$vivado_install"/*)
                case "${exe##*/}" in
                    vivado|vrs) printf "%s\n" "$pid" ;;
                esac
                ;;
        esac
    done
}

vivado_family_pids() {
    local -a pids
    local -a next
    local proc
    local pid
    local ppid
    local -A selected

    mapfile -t pids < <(vivado_seed_pids)
    for pid in "${pids[@]}"; do
        [[ -n "$pid" ]] && selected["$pid"]=1
    done

    # Include generic descendants (shells, Java, launchers) of the selected
    # vendor executables.  The named cgroup covers all new runs; this closes the
    # legacy/orphan gap for a run started before the named-scope guard existed.
    while :; do
        next=()
        for proc in /proc/[0-9]*; do
            pid="${proc##*/}"
            [[ -n "${selected[$pid]:-}" ]] && continue
            ppid="$(proc_ppid "$pid" 2>/dev/null || true)"
            if [[ -n "$ppid" && -n "${selected[$ppid]:-}" ]]; then
                next+=("$pid")
            fi
        done
        (( ${#next[@]} == 0 )) && break
        for pid in "${next[@]}"; do
            selected["$pid"]=1
        done
    done

    if (( ${#selected[@]} != 0 )); then
        for pid in "${!selected[@]}"; do
            printf "%s\n" "$pid"
        done | sort -n
    fi
}

scope_is_live() {
    local state

    state="$(systemctl --user show "$vivado_scope" -p ActiveState --value 2>/dev/null || true)"
    [[ "$state" == active || "$state" == activating || "$state" == deactivating ]]
}

stop_scoped_vivado() {
    local deadline

    scope_is_live || return
    echo "[vivado-exclusive] stopping prior guarded scope: $vivado_scope" >&2
    systemctl --user kill --kill-whom=all --signal=TERM "$vivado_scope" >/dev/null 2>&1 || true
    systemctl --user stop --no-block "$vivado_scope" >/dev/null 2>&1 || true
    deadline=$((SECONDS + terminate_timeout))
    while scope_is_live; do
        if (( SECONDS >= deadline )); then
            echo "[vivado-exclusive] forcing prior guarded scope: $vivado_scope" >&2
            systemctl --user kill --kill-whom=all --signal=KILL "$vivado_scope" >/dev/null 2>&1 || true
            systemctl --user stop --no-block "$vivado_scope" >/dev/null 2>&1 || true
            deadline=$((SECONDS + 10))
            while scope_is_live; do
                if (( SECONDS >= deadline )); then
                    echo "[vivado-exclusive] ERROR: guarded scope survived SIGKILL: $vivado_scope" >&2
                    exit 1
                fi
                sleep 1
            done
            break
        fi
        sleep 1
    done
}

stop_existing_vivado() {
    local -a pids
    local deadline
    local pid_csv

    stop_scoped_vivado
    mapfile -t pids < <(vivado_family_pids)
    if (( ${#pids[@]} == 0 )); then
        return
    fi

    echo "[vivado-exclusive] terminating existing Vivado PID(s): ${pids[*]}" >&2
    pid_csv="$(IFS=,; echo "${pids[*]}")"
    ps -o pid=,ppid=,pgid=,etime=,rss=,args= -p "$pid_csv" >&2 || true
    kill -TERM "${pids[@]}" 2>/dev/null || true

    deadline=$((SECONDS + terminate_timeout))
    while :; do
        mapfile -t pids < <(vivado_family_pids)
        if (( ${#pids[@]} == 0 )); then
            echo "[vivado-exclusive] previous Vivado processes exited" >&2
            return
        fi
        if (( SECONDS >= deadline )); then
            echo "[vivado-exclusive] forcing remaining Vivado PID(s): ${pids[*]}" >&2
            kill -KILL "${pids[@]}" 2>/dev/null || true
            # A killed parent can take a short time to reap all task workers.
            deadline=$((SECONDS + 10))
            while :; do
                mapfile -t pids < <(vivado_family_pids)
                if (( ${#pids[@]} == 0 )); then
                    echo "[vivado-exclusive] all prior Vivado processes are gone" >&2
                    return
                fi
                if (( SECONDS >= deadline )); then
                    echo "[vivado-exclusive] ERROR: Vivado survived SIGKILL: ${pids[*]}" >&2
                    exit 1
                fi
                sleep 1
            done
        fi
        sleep 1
    done
}

# The non-blocking probe makes a replacement launch preempt a run already
# guarded by this launcher.  After that run has been terminated, the blocking
# flock waits for its wrapper to reap it and release the lock.  The second
# cleanup closes the small race with a manually started Vivado process.
exec 9>"$lock_file"
if ! flock -n 9; then
    echo "[vivado-exclusive] another Ventium build owns $lock_file; replacing it" >&2
    stop_existing_vivado
fi
flock 9
stop_existing_vivado

echo "[vivado-exclusive] starting one Vivado run: vivado $*" >&2
# Xilinx's settings script references optional environment variables (including
# PYTHONPATH) before defining them.  Keep strict shell checking for this
# launcher, but disable nounset only while importing that vendor environment.
set +u
source /tools/Xilinx/2025.2/Vivado/settings64.sh
set -u
# Keep the sole Vivado parent and every synthesis/place/route descendant out of
# the same resource pool used by Verilator/QEMU builds.  The Tcl flow further
# fixes Vivado's internal worker count at one; this cgroup is the hard failure
# boundary if a vendor tool nevertheless fans out unexpectedly.
export VENTIUM_BUILD_MEMORY_MAX="${VENTIUM_VIVADO_MEMORY_MAX:-20G}"
export VENTIUM_BUILD_TASKS_MAX="${VENTIUM_VIVADO_TASKS_MAX:-32}"
export VENTIUM_BUILD_SCOPE_UNIT="ventium-vivado"
exec "$SCRIPT_DIR/../tools/build_scope.sh" -- "${VIVADO_BIN:-vivado}" "$@"
