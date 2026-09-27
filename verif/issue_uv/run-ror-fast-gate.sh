#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Compact rotate equivalence and opt-in register-ROR decode/datapath checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-ror-fast.XXXXXX)}"
mkdir -p "$OUT"
common=("$ROOT/rtl/ventium_pkg.sv"
        "$ROOT/rtl/core/ventium_alu_pkg.sv"
        "$ROOT/rtl/core/ventium_decode_pkg.sv"
        "$ROOT/rtl/core/ventium_sys_pkg.sv")
for top in tb_shrot_compact tb_ror_fast; do
  sources=("${common[@]}")
  if [[ "$top" == tb_ror_fast ]]; then
    sources+=("$ROOT/rtl/core/decode.sv" "$ROOT/rtl/core/u_pipe.sv")
  fi
  sources+=("$ROOT/verif/issue_uv/$top.sv")
  verilator --binary -j 1 --timing --assert -sv -Wno-fatal \
    -Wno-TIMESCALEMOD +define+VEN_FAST_ROR_IMM \
    --top-module "$top" -Mdir "$OUT/$top" "${sources[@]}" \
    > "$OUT/$top.build.log" 2>&1 || {
      tail -n 35 "$OUT/$top.build.log"; exit 1;
    }
  "$OUT/$top/V$top" > "$OUT/$top.run.log" 2>&1 || {
    tail -n 35 "$OUT/$top.run.log"; exit 1;
  }
done
rg 'SHROT-COMPACT-GATE-OK' "$OUT/tb_shrot_compact.run.log"
rg 'ROR-FAST-LEAF-OK' "$OUT/tb_ror_fast.run.log"
printf 'ROR-FAST-GATE-OK artifacts=%s\n' "$OUT"
