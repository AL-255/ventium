#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Run one *top-level* Ventium Vivado build at a time.
#
# Vivado itself is allowed to create the bounded synthesis workers selected by
# VEN_FPGA_JOBS.  What must never coexist is a second parent Vivado run: two
# runs can consume the entire host, swap heavily, and make both results
# untrustworthy.  This launcher deliberately has host-global semantics.  Each
# new invocation terminates every existing process whose executable name is
# exactly "vivado", including stale task workers, before starting its run.
#
# Do not invoke `vivado -mode batch ...` directly for this project.  Use:
#   fpga/run_vivado_exclusive.sh -mode batch -source ... -tclargs ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if (( $# == 0 )); then
    echo "usage: $0 <Vivado arguments>" >&2
    exit 64
fi

lock_file="${TMPDIR:-/tmp}/ventium-vivado-exclusive.lock"
terminate_timeout=45

vivado_pids() {
    # `-x` deliberately excludes this shell script, Tcl file names, log names,
    # and unrelated commands whose arguments merely contain the word vivado.
    pgrep -x vivado 2>/dev/null || true
}

stop_existing_vivado() {
    local -a pids
    local deadline
    local pid_csv

    mapfile -t pids < <(vivado_pids)
    if (( ${#pids[@]} == 0 )); then
        return
    fi

    echo "[vivado-exclusive] terminating existing Vivado PID(s): ${pids[*]}" >&2
    pid_csv="$(IFS=,; echo "${pids[*]}")"
    ps -o pid=,ppid=,pgid=,etime=,rss=,args= -p "$pid_csv" >&2 || true
    kill -TERM "${pids[@]}" 2>/dev/null || true

    deadline=$((SECONDS + terminate_timeout))
    while :; do
        mapfile -t pids < <(vivado_pids)
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
                mapfile -t pids < <(vivado_pids)
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
exec "$SCRIPT_DIR/../tools/build_scope.sh" -- "${VIVADO_BIN:-vivado}" "$@"
