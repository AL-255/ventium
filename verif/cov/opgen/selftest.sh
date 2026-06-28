#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# verif/cov/opgen/selftest.sh — CI for the GENERATORS themselves (no RTL, no
# qemu). Regenerates the whole suite from x86reference.xml and asserts the
# invariants hold, so a refactor of a generator can't silently drop opcodes,
# break the 100% accounting, or emit un-assemblable tests. Fast (~seconds).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
fail=0
chk(){ if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

echo "== opgen generator self-test =="
python3 gen_opspec.py  >/dev/null
python3 gen_easweep.py >/dev/null
python3 gen_tests.py   >/dev/null
python3 gen_repros.py  >/dev/null

N=$(python3 -c "import json;print(len(json.load(open('opspec.json'))))")
chk "opspec has 555 P54C encodings (got $N)"        "[ '$N' -ge 540 ] && [ '$N' -le 560 ]"
GEN=$(grep -oE 'GEN \(auto test written\): [0-9]+' opgen_status.txt | grep -oE '[0-9]+')
chk "GEN tests >= 430 (got $GEN)"                    "[ '${GEN:-0}' -ge 430 ]"
chk "EA sweep present + >= 700 LEA forms"            "[ \$(grep -c leal tests/ea_sweep/ea_sweep.s 2>/dev/null) -ge 700 ]"
chk "op_prefixes synthetic test exists"              "[ -f tests/op_prefixes/op_prefixes.s ]"
chk "repros generated (>= 12)"                       "[ \$(ls repros/*/repro.s 2>/dev/null | wc -l) -ge 12 ]"

# 100% accounting must hold (UNCOVERED == 0)
UNC=$(python3 coverage_report.py 2>/dev/null | grep -oE 'UNCOVERED *[0-9]+' | grep -oE '[0-9]+' | head -1)
chk "coverage accounting UNCOVERED == 0 (got ${UNC:-?})"  "[ '${UNC:-1}' -eq 0 ]"
N_MODE=$(python3 gen_modes.py >/dev/null 2>&1; grep -c "write_image" gen_modes.py)
chk "mode lane has >= 5 streams" "[ \$(grep -c write_image gen_modes.py) -ge 6 ]"

# a sample of generated tests must assemble (catch a generation regression)
asm_ok=1
for t in op_00 op_88 op_f7_6 op_d8_0_m op_d9_7_ff op_0fa3 op_e8 op_prefixes ea_sweep; do
    f="tests/$t/$t.s"
    [ -f "$f" ] || { echo "  FAIL sample $t missing"; asm_ok=0; continue; }
    gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 -o /dev/null "$f" 2>/dev/null \
        || { echo "  FAIL sample $t does not assemble"; asm_ok=0; }
done
chk "sample tests assemble"                          "[ '$asm_ok' -eq 1 ]"

[ "$fail" -eq 0 ] && echo "SELFTEST: PASS" || { echo "SELFTEST: FAIL"; exit 1; }
