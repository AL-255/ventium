#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Exact architectural regression for a memory-destination x87 command.  It is
# deliberately self-checked: the wrong implementation can still eventually
# write the page after the handler fixes its PTE, but it has already popped ST0
# and therefore cannot produce the required integer 3 on the restarted FISTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST="$ROOT/verif/sys/tests/pfpstore"
BIN="${TB_BIN:-$ROOT/verif/tb/obj_dir/tb_ventium}"
OUT="${PFPSTORE_OUT:-/tmp/ventium-pfpstore}"

test -x "$BIN" || { echo "PFPSTORE-GATE-FAIL: tb missing: $BIN"; exit 1; }
make -s -C "$TEST"
rm -rf "$OUT"
mkdir -p "$OUT"

set +e
timeout 180 "$BIN" --system --cosim --x87 --image "$TEST/pfpstore.bin" \
  --out "$OUT/pfpstore.vtrace" --max-insn 500 --quiesce 8000 +ven_faultlog \
  >"$OUT/pfpstore.log" 2>&1
RC=$?
set -e
[ "$RC" != 124 ] || { echo "PFPSTORE-GATE-FAIL: run hung"; exit 1; }

python3 - "$OUT/pfpstore.vtrace" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])
           if line.strip() and not line.startswith('{"vtrace"')]
assert records, "no trace records"
r = records[-1]
h = lambda name: int(r[name], 16)
assert h("ecx") == 3, f"ecx={r['ecx']}: expected exactly #PF/#GP/#UD"
assert h("edx") == 0x004000f4, f"edx={r['edx']}: CR2 witness is not 0x00401000"
assert h("edi") == 3, f"edi={r['edi']}: #PF error is not P|W=3"
assert h("esi") == 3, f"esi={r['esi']}: FISTP did not preserve ST0 until restart"
print(f"  final witnesses: ecx=3 edx={r['edx']} edi=3 esi=3")
PY

PF=$(grep -c '^\[FAULT\] vec=14 .*err=00000003' "$OUT/pfpstore.log" || true)
GP=$(grep -c '^\[FAULT\] vec=13 .*err=00000038' "$OUT/pfpstore.log" || true)
ALL=$(grep -c '^\[FAULT\] vec=' "$OUT/pfpstore.log" || true)
# The debug fault log records the architecturally interesting #PF/#GP cases;
# #UD is independently witnessed by ECX=3 in the guest but has no log line.
[ "$PF" = 1 ] && [ "$GP" = 1 ] && [ "$ALL" = 2 ] || {
  echo "PFPSTORE-GATE-FAIL: #PF(err=3)=$PF #GP(err=38)=$GP all=$ALL (want 1/1/2)"
  exit 1
}
echo "PFPSTORE-GATE-OK: write-protected FISTP faulted before x87 state mutation"
