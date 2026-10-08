#!/usr/bin/env bash
# Experimental registered-translation cache only; NOT a core/FPGA acceptance gate.
set -euo pipefail
ulimit -c 0
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_scratch=/home/yukidama/external/tmp
[[ "$(findmnt -T "$task_scratch" -no FSTYPE)" == ext4 ]]
[[ "$(df -B1 --output=avail "$task_scratch" | tail -n 1)" -gt 134217728 ]]
task_out="$(mktemp -d "$task_scratch/ventium-fe-dtlb-leaf.XXXXXX")"
export TMPDIR="$task_out"
printf 'Experimental FE DTLB evidence: %s\n' "$task_out"
task_dut="$task_repo/verif/fe_pipe/prototype/ven_fe_dtlb.sv"
task_tb="$task_repo/verif/fe_pipe/tb_fe_dtlb.sv"
sha256sum "$task_dut" "$task_tb" "${BASH_SOURCE[0]}" > "$task_out/inputs.sha256"
set +e
"$task_repo/tools/build_scope.sh" -- timeout --signal=TERM --kill-after=5s 120s \
 verilator --binary --timing --assert -j 1 -Wno-fatal \
 -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
 -Werror-LATCH -Werror-UNOPTFLAT --top-module tb_fe_dtlb \
 --Mdir "$task_out/obj" -o tb_fe_dtlb "$task_dut" "$task_tb" \
 > "$task_out/build.log" 2>&1
rc=$?
printf '%s\n' "$rc" > "$task_out/build.exit"
if ((rc)); then tail -30 "$task_out/build.log"; exit "$rc"; fi
timeout --signal=TERM --kill-after=5s 30s "$task_out/obj/tb_fe_dtlb" > "$task_out/run.log" 2>&1
rc=$?
printf '%s\n' "$rc" > "$task_out/run.exit"
set -e
sha256sum --strict -c "$task_out/inputs.sha256" > "$task_out/pins-after.log"
sha256sum "$task_out/obj/tb_fe_dtlb" > "$task_out/native.sha256"
cat "$task_out/run.log"
((rc == 0))
rg -q '^FE-DTLB-LEAF-OK ' "$task_out/run.log"
