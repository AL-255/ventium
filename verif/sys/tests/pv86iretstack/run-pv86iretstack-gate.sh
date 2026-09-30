#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt whole-core only; invoke under build_scope with an outer <=600s timeout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
"$ROOT/tools/build_scope.sh" --is-active || {
  echo 'pv86iretstack requires the existing bounded build_scope launcher' >&2; exit 2;
}
: "${TB_BIN:?Provide the current frozen prebuilt tb_ventium; this gate never rebuilds it}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
[[ -x "$TB" && -x "$QEMU" ]] || { echo 'Missing pinned binary' >&2; exit 2; }
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-pv86iretstack.XXXXXX)}"
mkdir -p "$OUT"
printf 'Artifacts: %s\n' "$OUT"
sha256sum "$TB" > "$OUT/binary.sha256"
failed=0
for case_id in ${CASES:-1 2 3 4 5}; do
  [[ "$case_id" =~ ^[1-5]$ ]] || { echo 'CASES must contain only 1..5' >&2; exit 2; }
  image="$OUT/pv86iretstack_$case_id"
  make -C "$ROOT/verif/sys/tests/pv86iretstack" OUTDIR="$OUT" CASE="$case_id" > "$image.build.log" 2>&1
  nm -n "$image.elf" > "$image.sym"
  timeout --kill-after=5s 90s python3 "$ROOT/verif/qemu-trace/gen_trace.py" \
    --qemu "$QEMU" --system --image "$image.bin" --image-mode bios \
    --max-insn 1800 --port "${QEMU_PORT:-41431}" --out "$image.qemu.vtrace" \
    > "$image.qemu.log" 2>&1
  python3 - "$image.qemu.vtrace" "$case_id" <<'PY'
import json,sys
rows=[r for line in open(sys.argv[1]) if 'pc' in (r:=json.loads(line))]
case=int(sys.argv[2])
assert len(rows)<1800 and rows, ('golden incomplete', len(rows))
assert int(rows[-1]['ebp'],0)==0x49525300+case, ('golden self-check failed',rows[-1])
assert int(rows[-1]['eax'],0)==0x42, ('golden exit not success',rows[-1])
print(f'QEMU self-check PASS case={case} records={len(rows)}')
PY
  set +e
  timeout --kill-after=5s 30s "$TB" --system --cosim --image "$image.bin" \
    --max-insn 1800 --max-cycles 500000 --quiesce 400 \
    --out "$image.rtl.vtrace" +ven_faultlog > "$image.rtl.log" 2>&1
  rtl_status=$?
  python3 "$ROOT/verif/diff/compare.py" --mode func --all \
    "$image.qemu.vtrace" "$image.rtl.vtrace" > "$image.diff.log" 2>&1
  diff_status=$?
  set -e
  if [[ "$rtl_status" != 133 || "$diff_status" != 0 ]]; then
    printf 'PV86-IRETSTACK-FAIL case=%s rtl_exit=%s diff_exit=%s\n' "$case_id" "$rtl_status" "$diff_status"
    sed -n '1,12p' "$image.diff.log"
    rg '^\[FAULT\]|tb: stop|tb:.*exit|tb:.*halt' "$image.rtl.log" | tail -n 8 || true
    failed=1
  else
    printf 'PV86-IRETSTACK-PASS case=%s\n' "$case_id"
  fi
done
(( failed==0 )) || exit 1
echo 'PV86-IRETSTACK-GATE-OK: full QEMU states, translated V86 frames, highESP/SP-wrap/word-boundary/SS.B0 entry'
