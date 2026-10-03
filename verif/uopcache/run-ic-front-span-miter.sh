#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Compile a tiny standalone production-vs-oracle miter for the marked IC front
# span.  This is intentionally not a whole-core or differential gate.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi

ulimit -c 0
artifact_root="${VENTIUM_IC_FRONT_SPAN_ARTIFACT_ROOT:-/var/tmp}"
if [ ! -d "$artifact_root" ]; then
  artifact_root="/var/tmp"
fi
test_tmp_dir="${VENTIUM_IC_FRONT_SPAN_TMPDIR:-/var/tmp}"
if [ ! -d "$test_tmp_dir" ] || [ ! -w "$test_tmp_dir" ]; then
  echo "IC-FRONT-SPAN-FAIL: compiler temporary directory is not writable: $test_tmp_dir" >&2
  exit 2
fi
OUT="$(mktemp -d "$artifact_root/ventium-ic-front-span.XXXXXX")"
if [ "${VENTIUM_KEEP_IC_FRONT_SPAN_ARTIFACTS:-0}" = "0" ]; then
  trap 'rm -rf -- "$OUT"' EXIT
fi
echo "Artifacts: $OUT"

python3 "$ROOT/verif/uopcache/gen_ic_front_span_miter.py" \
  --core "$ROOT/rtl/core/core.sv" \
  --output "$OUT/ic_front_span_extracted.svh" | tee "$OUT/extract.log"
sha256sum "$ROOT/rtl/core/core.sv" "$OUT/ic_front_span_extracted.svh" \
  | tee "$OUT/input-sha256.txt"

run_seg_ext_size_guard() {
  local seg_dir="$OUT/seg-ext-size"
  mkdir -p "$seg_dir"
  python3 "$ROOT/verif/uopcache/gen_seg_ext_size_guard.py" \
    --core "$ROOT/rtl/core/core.sv" \
    --output "$seg_dir/seg_ext_size_extracted.svh" | tee "$seg_dir/extract.log"
  for synthesis_mode in no_synthesis synthesis; do
    local preprocess_args=(+define+VEN_SEG_ENFORCE)
    local compile_args=(+define+VEN_SEG_ENFORCE)
    if [ "$synthesis_mode" = synthesis ]; then
      preprocess_args+=(+define+SYNTHESIS)
      compile_args+=(+define+SYNTHESIS)
    fi
    timeout 60s "$ROOT/tools/verilator_serial.sh" -E -sv \
      +incdir+"$ROOT/rtl/core" +incdir+"$ROOT/rtl/fpu" \
      "${preprocess_args[@]}" "$ROOT/rtl/core/core.sv" \
      >"$seg_dir/preprocessed-$synthesis_mode.sv" \
      2>"$seg_dir/preprocess-$synthesis_mode.log" \
      || { cat "$seg_dir/preprocess-$synthesis_mode.log"; return 1; }
    python3 - "$seg_dir/preprocessed-$synthesis_mode.sv" "$synthesis_mode" <<'PY' | tee "$seg_dir/preprocess-count-$synthesis_mode.log"
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
count = len(re.findall(r"(?m)^\s*assign\s+seg_ext_size\s*=", text))
if count != 1:
    raise SystemExit(f"SEG-EXT-SIZE-PREPROCESS-FAIL mode={sys.argv[2]} assignments={count}")
print(f"SEG-EXT-SIZE-PREPROCESS-OK mode={sys.argv[2]} assignments={count}")
PY
    TMPDIR="$test_tmp_dir" timeout 120s "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall \
      -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
      -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
      --top-module tb_seg_ext_size_guard -I"$seg_dir" \
      -Mdir "$seg_dir/$synthesis_mode-obj" "${compile_args[@]}" \
      "$ROOT/verif/uopcache/tb_seg_ext_size_guard.sv" \
      >"$seg_dir/build-$synthesis_mode.log" 2>&1 \
      || { tail -80 "$seg_dir/build-$synthesis_mode.log"; return 1; }
    timeout 60s "$seg_dir/$synthesis_mode-obj/Vtb_seg_ext_size_guard" \
      >"$seg_dir/run-$synthesis_mode.log" 2>&1 \
      || { cat "$seg_dir/run-$synthesis_mode.log"; return 1; }
    cat "$seg_dir/run-$synthesis_mode.log"
    rg -q "^SEG-EXT-SIZE-MUX-OK synthesis=$([ "$synthesis_mode" = synthesis ] && echo 1 || echo 0) checks=8192$" \
      "$seg_dir/run-$synthesis_mode.log"
  done
}

if [ "${1:-}" = "--seg-only" ]; then
  if [ "$#" -ne 1 ]; then
    echo "usage: $0 [--seg-only]" >&2
    exit 2
  fi
  run_seg_ext_size_guard
  echo "IC-FRONT-SPAN-SEG-ONLY-OK"
  exit 0
fi
if [ "$#" -ne 0 ]; then
  echo "usage: $0 [--seg-only]" >&2
  exit 2
fi

run_variant() {
  local variant_name="$1"
  shift
  local variant_dir="$OUT/$variant_name"
  mkdir -p "$variant_dir"
  TMPDIR="$test_tmp_dir" timeout 120s "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall \
    -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
    -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    --top-module tb_ic_front_span_miter -I"$OUT" -Mdir "$variant_dir/obj" \
    "$@" "$ROOT/verif/uopcache/tb_ic_front_span_miter.sv" \
    >"$variant_dir/build.log" 2>&1 \
    || { tail -80 "$variant_dir/build.log"; return 1; }
  timeout 60s "$variant_dir/obj/Vtb_ic_front_span_miter" \
    >"$variant_dir/run.log" 2>&1 \
    || { tail -80 "$variant_dir/run.log"; return 1; }
  cat "$variant_dir/run.log"
}

run_variant bram_bypass +define+VEN_IC_BRAM
rg -q '^IC-FRONT-SPAN-MITER-OK bypass=1$' "$OUT/bram_bypass/run.log"
run_variant bram_no_bypass +define+VEN_IC_BRAM +define+VEN_IC_NO_FETCH_BYPASS
rg -q '^IC-FRONT-SPAN-MITER-OK bypass=0$' "$OUT/bram_no_bypass/run.log"
run_variant nonbram_bypass
rg -q '^IC-FRONT-SPAN-NONBRAM-SMOKE-OK ' "$OUT/nonbram_bypass/run.log"
run_variant nonbram_no_bypass +define+VEN_IC_NO_FETCH_BYPASS
rg -q '^IC-FRONT-SPAN-NONBRAM-SMOKE-OK ' "$OUT/nonbram_no_bypass/run.log"

run_seg_ext_size_guard

echo "IC-FRONT-SPAN-GATE-OK"
