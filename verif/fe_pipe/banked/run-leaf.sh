#!/usr/bin/env bash
# Tiny independent <=2 GiB leaf builds; never launch or preempt Vivado.
set -euo pipefail
set -C
ulimit -c 0
task_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task_repo="$(cd "$task_here/../../.." && pwd)"
task_scratch=/home/yukidama/external/tmp
[[ "$(findmnt -T "$task_scratch" -no FSTYPE)" == ext4 ]]
[[ "$(df -B1 --output=avail "$task_scratch" | tail -n 1)" -gt 268435456 ]]
[[ "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)" -gt 4194304 ]]
task_out="$(mktemp -d "$task_scratch/ventium-fe-banked-leaf.XXXXXX")"
export TMPDIR="$task_out"
printf 'Experimental banked evidence: %s\n' "$task_out"
sha256sum "$task_here/ven_fe_dtlb.sv" "$task_here/tb_fe_banked.sv" \
  "$task_here/run-leaf.sh" "$task_here/../permission/ven_fe_dtlb.sv" \
  "$task_here/../permission/tb_fe_parent_perm.sv" "$task_repo/rtl/mem/tlb_assoc.sv" \
  > "$task_out/inputs.sha256"
for variant in leaf parent negative-fill negative-capacity; do
  task_top=tb_fe_banked
  task_source="$task_here/ven_fe_dtlb.sv"
  task_test="$task_here/tb_fe_banked.sv"
  task_defs=()
  if [[ "$variant" == parent || "$variant" == negative-fill ]]; then
    task_top=tb_fe_parent_perm
    task_test="$task_here/../permission/tb_fe_parent_perm.sv"
  fi
  if [[ "$variant" == negative-fill ]]; then task_defs+=(+define+NEGATIVE_KEEP_CHILD_ON_FILL); fi
  if [[ "$variant" == negative-capacity ]]; then task_source="$task_here/../permission/ven_fe_dtlb.sv"; fi
  task_unit="ventium-fe-banked-${task_out##*.}-${variant}.scope"
  set +e
  systemd-run --user --scope --quiet --unit="$task_unit" \
    -p MemoryMax=2G -p MemorySwapMax=0 -- timeout --signal=TERM --kill-after=5s 120s \
    verilator --binary --timing --assert -j 2 -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT --top-module "$task_top" \
    --Mdir "$task_out/obj_$variant" -o "$task_top" "${task_defs[@]}" \
    "$task_source" "$task_repo/rtl/mem/tlb_assoc.sv" "$task_test" \
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
  case "$variant" in
    negative-fill)
      ((rc != 0 && rc != 124 && rc != 137))
      rg -q 'hit owner stale|permission/payload owner stale' "$task_out/$variant-run.log" ;;
    negative-capacity)
      ((rc != 0 && rc != 124 && rc != 137))
      rg -q '64-page capacity retention failed' "$task_out/$variant-run.log" ;;
    *)
      ((rc == 0))
      rg -q 'FE-BANKED-LEAF-OK|FE-PARENT-PERM-OK' "$task_out/$variant-run.log" ;;
  esac
done
sha256sum --strict -c "$task_out/inputs.sha256" > "$task_out/pins-after.log"
printf 'FE-BANKED-LEAF-CLOSED-OK (not full-core or physical acceptance)\n'
