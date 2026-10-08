#!/usr/bin/env bash
# Preserve native logs; a passing leaf is not whole-core or FPGA acceptance.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=/home/yukidama/external/tmp
test -d "$scratch" && test -w "$scratch"
test "$(findmnt -T "$scratch" -no FSTYPE)" = ext4
export TMPDIR="$scratch"
out=$(mktemp -d "$scratch/ventium-uv-shift-flags.XXXXXX")
printf 'UV shift flag evidence: %s\n' "$out"
sha256sum "$root/rtl/core/uv_common.sv" "$root/rtl/core/u_pipe.sv" \
  "$root/rtl/core/ventium_alu_pkg.sv" "$root/rtl/core/ventium_decode_pkg.sv" \
  "$root/rtl/core/decode.sv" "$root/rtl/core/issue_uv.sv" \
  "$root/rtl/ventium_pkg.sv" "$root/verif/issue_uv/tb_uv_shift_flags.sv" \
  "$0" > "$out/inputs.sha256"
overall=0
for profile in shifts ror; do
  # Each temporary leaf needs about 180 MiB during compilation. Retain the
  # binary/logs but release its reproducible PCH cache before the next profile.
  test "$(df -B1 --output=avail "$scratch" | tail -n 1)" -gt 400000000
  defs=(+define+VEN_FAST_BYTE_SHIFT)
  [[ "$profile" != ror ]] || defs+=(+define+VEN_FAST_ROR_IMM)
  set +e
  "$root/tools/build_scope.sh" -- timeout --signal=TERM --kill-after=5s 120s \
    "$root/tools/verilator_serial.sh" --binary --assert -sv -j 1 \
    +define+VTM_NO_DPI "${defs[@]}" -Wno-UNUSED -Wno-TIMESCALEMOD \
    --top-module tb_uv_shift_flags --Mdir "$out/$profile" -o tb_uv_shift_flags \
    "$root/rtl/ventium_pkg.sv" "$root/rtl/core/ventium_alu_pkg.sv" \
    "$root/rtl/core/ventium_decode_pkg.sv" "$root/rtl/core/decode.sv" \
    "$root/rtl/core/issue_uv.sv" "$root/rtl/core/u_pipe.sv" \
    "$root/rtl/core/uv_common.sv" "$root/verif/issue_uv/tb_uv_shift_flags.sv" \
    > "$out/$profile-build.log" 2>&1
  build_rc=$?
  printf '%s\n' "$build_rc" > "$out/$profile-build.exit"
  set -e
  if (( build_rc )); then tail -n 35 "$out/$profile-build.log"; exit "$build_rc"; fi
  set +e
  (ulimit -c 0; timeout --signal=TERM --kill-after=5s 30s "$out/$profile/tb_uv_shift_flags") \
    > "$out/$profile-run.log" 2>&1
  run_rc=$?
  printf '%s\n' "$run_rc" > "$out/$profile-run.exit"
  set -e
  cat "$out/$profile-run.log"
  sha256sum "$out/$profile/tb_uv_shift_flags" > "$out/$profile-binary.sha256"
  for kind in fast slow; do
    pch="$out/$profile/Vtb_uv_shift_flags__pch.h.$kind.gch"
    if [[ -f "$pch" && ! -L "$pch" ]]; then
      rm -- "$pch"
      printf 'Removed rebuildable PCH: %s\n' "$pch" >> "$out/cache-cleanup.log"
    fi
  done
  if (( run_rc != 0 )) || ! rg -q '^UV-SHIFT-FLAGS-OK$' "$out/$profile-run.log"; then
    overall=1
  fi
done
sha256sum --strict -c "$out/inputs.sha256" > "$out/inputs-after.log"
exit "$overall"
