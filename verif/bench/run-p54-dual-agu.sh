#!/usr/bin/env bash
# Bounded exhaustive base/index/scale/enable witness for both ModR/M AGUs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$root/tools/build_scope.sh" --is-active; then
  exec "$root/tools/build_scope.sh" -- bash "$0" "$@"
fi
out="$(mktemp -d "${TMPDIR:-/tmp}/ventium-p54-dual-agu.XXXXXX")"
echo "Artifacts: $out"
timeout --signal=TERM --kill-after=10s 300s "$root/tools/verilator_serial.sh" \
  --binary --timing --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module tb_p54_dual_agu -Mdir "$out" \
  "$root/rtl/core/ventium_decode_pkg.sv" \
  "$root/rtl/core/ven_p54_dual_agu.sv" \
  "$root/verif/bench/tb_p54_dual_agu.sv" > "$out/build.log" 2>&1 || {
    tail -50 "$out/build.log"
    exit 1
  }
timeout --signal=TERM --kill-after=10s 20s "$out/Vtb_p54_dual_agu"
