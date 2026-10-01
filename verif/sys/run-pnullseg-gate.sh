#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Intel-spec null-segment witness. No QEMU differential oracle for null use.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
fail() { echo "PNULLSEG-GATE-FAIL: $*" >&2; exit 1; }
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi

TDIR="$ROOT/verif/sys/tests/pnullseg"
make -C "$TDIR"
if [[ -z "${TB_BIN:-}" ]]; then
  # The canonical model deliberately omits per-access segment enforcement.
  # Never overwrite it or silently interpret permissive QEMU as this oracle.
  make -C "$ROOT/verif/tb" rtl OBJDIR=obj_dir_pnullseg \
    VL_EXTRA_DEFINES=+define+VEN_SEG_ENFORCE
  TB_BIN="$ROOT/verif/tb/obj_dir_pnullseg/tb_ventium"
fi
TB="$(realpath -e "$TB_BIN")"
[[ -x "$TB" ]] || fail "missing frozen or separately built TB"
RECORD="$(dirname "$TB")/Vventium_top__verFiles.dat"
[[ -f "$RECORD" ]] || fail "missing colocated Verilator compile record"
TB_SHA="${TB_SHA256:-$(sha256sum "$TB" | cut -d' ' -f1)}"
RECORD_SHA="${TB_COMPILE_SHA256:-$(sha256sum "$RECORD" | cut -d' ' -f1)}"
[[ "$(sha256sum "$TB" | cut -d' ' -f1)" == "$TB_SHA" ]] || fail "TB hash mismatch"
[[ "$(sha256sum "$RECORD" | cut -d' ' -f1)" == "$RECORD_SHA" ]] || fail "compile-record hash mismatch"
# Check the actual recorded command before launching. Its hash/colocation are
# supplementary provenance, not a replacement for the caller's build receipt.
PYTHONPATH="$TDIR" python3 -B - "$RECORD" <<'PY'
from pathlib import Path
import sys
import check_witness
check_witness.compile_profile(Path(sys.argv[1]).read_text())
PY

if [[ -n "${PNULLSEG_OUTDIR:-}" ]]; then
  OUT="$PNULLSEG_OUTDIR"
  [[ "$OUT" == /* && ! -e "$OUT" && ! -L "$OUT" ]] || fail "output must be a fresh absolute leaf"
  PARENT="$(dirname "$OUT")"
  [[ -d "$PARENT" && "$(stat -c %u "$PARENT")" == "$UID" \
     && "$(realpath -m "$OUT")" == "$OUT" ]] || fail "output parent must be owned and unaliased"
  mkdir -m 700 "$OUT"
else
  OUT="$(mktemp -d "$(dirname "$TB")/pnullseg.XXXXXX")"
fi
echo "PNULLSEG artifacts: $OUT"
sha256sum "$TB" "$RECORD" "$TDIR/pnullseg.bin" "$TDIR/pnullseg.elf" \
  "$TDIR/pnullseg.S" "$TDIR/pnullseg.ld" "$TDIR/Makefile" \
  "$TDIR/manifest.json" "$TDIR/check_witness.py" \
  "$ROOT/verif/diff/tracefmt.py" "$ROOT/verif/sys/run-pnullseg-gate.sh" \
  > "$OUT/inputs.sha256"
RC=0
timeout --kill-after=3s 30s "$TB" --cosim --system --image "$TDIR/pnullseg.bin" \
  --out "$OUT/rtl.vtrace" --max-insn 1200 --max-cycles 1000000 --quiesce 400 \
  +ven_faultlog > "$OUT/rtl.log" 2>&1 || RC=$?
printf '%s\n' "$RC" > "$OUT/return-code.txt"
timeout --kill-after=3s 10s python3 -B "$TDIR/check_witness.py" \
  --trace "$OUT/rtl.vtrace" --log "$OUT/rtl.log" --return-code "$RC" \
  --tb-bin "$TB" --tb-sha256 "$TB_SHA" --compile-record "$RECORD" \
  --compile-sha256 "$RECORD_SHA" > "$OUT/witness.json" \
  || fail "closed witness failed; see $OUT/rtl.log and witness.json"
sha256sum -c "$OUT/inputs.sha256" > "$OUT/input-stability.log" \
  || fail "input/source changed during witness"
echo "PNULLSEG-GATE-OK: four precise GP0/no-effect witnesses and six legal controls; not OS acceptance"
