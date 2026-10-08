#!/usr/bin/env bash
# Experimental permission snapshot checks, NOT a core/FPGA acceptance gate.
set -euo pipefail
set -C
ulimit -c 0
task_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task_repo="$(cd "$task_here/../../.." && pwd)"
task_scratch=/home/yukidama/external/tmp
[[ "$(findmnt -T "$task_scratch" -no FSTYPE)" == ext4 ]]
[[ "$(df -B1 --output=avail "$task_scratch" | tail -n 1)" -gt 268435456 ]]
task_out="$(mktemp -d "$task_scratch/ventium-fe-permission-leaf.XXXXXX")"
export TMPDIR="$task_out"
printf 'Experimental permission evidence: %s\n' "$task_out"
sha256sum "$task_here/ven_fe_dtlb.sv" "$task_repo/rtl/mem/tlb_assoc.sv" \
  "$task_here/tb_fe_dtlb_perm.sv" "$task_here/tb_fe_parent_perm.sv" \
  "$task_here/run-leaf.sh" > "$task_out/inputs.sha256"
for variant in leaf parent negative; do
  task_top=tb_fe_dtlb_perm
  task_defs=()
  if [[ "$variant" != leaf ]]; then task_top=tb_fe_parent_perm; fi
  if [[ "$variant" == negative ]]; then task_defs+=(+define+NEGATIVE_KEEP_CHILD_ON_FILL); fi
  set +e
  "$task_repo/tools/build_scope.sh" -- timeout --signal=TERM --kill-after=5s 120s \
    verilator --binary --timing --assert -j 1 -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT --top-module "$task_top" \
    --Mdir "$task_out/obj_$variant" -o "$task_top" "${task_defs[@]}" \
    "$task_here/ven_fe_dtlb.sv" "$task_repo/rtl/mem/tlb_assoc.sv" "$task_here/$task_top.sv" \
    > "$task_out/$variant-build.log" 2>&1
  rc=$?
  printf '%s\n' "$rc" > "$task_out/$variant-build.exit"
  if ((rc)); then tail -30 "$task_out/$variant-build.log"; exit "$rc"; fi
  timeout --signal=TERM --kill-after=5s 30s "$task_out/obj_$variant/$task_top" \
    > "$task_out/$variant-run.log" 2>&1
  rc=$?
  printf '%s\n' "$rc" > "$task_out/$variant-run.exit"
  set -e
  cat "$task_out/$variant-run.log"
  sha256sum "$task_out/obj_$variant/$task_top" > "$task_out/$variant-native.sha256"
  if [[ "$variant" == negative ]]; then
    # A timeout or unrelated error is not a useful negative control.
    ((rc != 0 && rc != 124 && rc != 137))
    rg -q 'hit owner stale|permission/payload owner stale' "$task_out/$variant-run.log"
  else
    ((rc == 0))
    rg -q 'FE-DTLB-PERM-LEAF-OK|FE-PARENT-PERM-OK' "$task_out/$variant-run.log"
  fi
done
sha256sum --strict -c "$task_out/inputs.sha256" > "$task_out/pins-after.log"
printf 'FE-PERM-LEAF-AND-PARENT-CLOSED-OK\n'
