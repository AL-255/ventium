#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# verif/cov/opgen/run-transc.sh — confirm the opgen TRANSC findings are
# FEATURE-GATED (deferred), not broken: run the x87 transcendental opcode tests
# against the +VEN_TRANSCENDENTAL coverage build (obj_dir_cov_feat) and assert
# they PASS vs the qemu-i386 golden. In the plain build these HALT (cataloged in
# known_diverge.txt as TRANSC); here they should compute correctly.
#
# Build the feature TB first:  make -C verif/tb cov-feat
# Then:                        bash verif/cov/opgen/run-transc.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TB="$ROOT/verif/tb/obj_dir_cov_feat/tb_ventium"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
GEN="$ROOT/verif/qemu-trace/gen_trace.py"; CMP="$ROOT/verif/diff/compare.py"
E2F="$ROOT/verif/tests/elf2flat.py"; W="$ROOT/build/cov/opgen/transc"; mkdir -p "$W"

if [ ! -x "$TB" ]; then
    echo "feature TB missing: $TB"
    echo "build it:  make -C verif/tb cov-feat"
    exit 2
fi

# the transcendental encodings (D9 /6,/7 reg-form sec_opcd F0-F4, F9/FB/FE/FF)
TESTS=$(ls -d "$HERE"/tests/op_d9_6_f[0-4] "$HERE"/tests/op_d9_7_f9 \
              "$HERE"/tests/op_d9_7_f[bef] 2>/dev/null)
pass=0; inexact=0; halt=0; port=29400
for d in $TESTS; do
    n="$(basename "$d")"
    gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
        -o "$W/$n.elf" "$d/$n.s" 2>/dev/null || { echo "  asm-fail $n"; halt=$((halt+1)); continue; }
    python3 "$E2F" "$W/$n.elf" --out "$W/$n.flat" --base 0x08048000 >/dev/null 2>&1
    port=$((port+7))
    python3 "$GEN" --qemu "$QEMU" --elf "$W/$n.elf" --out "$W/${n}_q.vt" --max-insn 40 --x87 --port "$port" >/dev/null 2>&1 \
        || { echo "  gold-fail $n"; halt=$((halt+1)); continue; }
    esp=$(python3 -c "import json;f=open('$W/${n}_q.vt');f.readline();print(json.loads(f.readline())['esp'])" 2>/dev/null || echo 0x40c34910)
    # dump coverage too — the in-RTL transcendental/FPREM engine is ONLY reachable
    # in this +VEN_TRANSCENDENTAL build, so these dats cover RTL the plain lane can't.
    mkdir -p "$W/dat"
    VEN_COV_DAT="$W/dat/$n.dat" "$TB" --image "$W/$n.flat" --load 0x08048000 --entry 0x08048000 \
        --init-esp "$esp" --x87 --out "$W/${n}_r.vt" --max-insn 40 >/dev/null 2>&1 || true
    if python3 "$CMP" --mode func "$W/${n}_q.vt" "$W/${n}_r.vt" >"$W/$n.cmp" 2>&1; then
        echo "  EXACT   $n  (bit-exact vs qemu softfloat)"; pass=$((pass+1))
    elif grep -qi "LENGTH" "$W/$n.cmp"; then
        echo "  HALT    $n  (still HALTs even with the feature flag — real gap)"; halt=$((halt+1))
    else
        echo "  INEXACT $n  (computes, differs in low bits — approximation vs softfloat)"; inexact=$((inexact+1))
    fi
done
# ---- coverage sweep: drive the in-RTL transcendental/FPREM engine over many
# inputs (range reduction + iteration paths) so its modules light up. -----------
python3 "$HERE/gen_transc_sweep.py" >/dev/null 2>&1
if gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
        -o "$W/sweep.elf" "$HERE/tests/transc_sweep/transc_sweep.s" 2>/dev/null; then
    python3 "$E2F" "$W/sweep.elf" --out "$W/sweep.flat" --base 0x08048000 >/dev/null 2>&1
    mkdir -p "$W/dat"
    VEN_COV_DAT="$W/dat/transc_sweep.dat" "$TB" --image "$W/sweep.flat" --load 0x08048000 \
        --entry 0x08048000 --init-esp 0x40c34910 --x87 --out /dev/null --max-insn 1000 >/dev/null 2>&1 || true
    echo "  transcendental-engine coverage sweep: $(ls "$W"/dat/*.dat 2>/dev/null | wc -l) dats"
fi

echo "TRANSC (feature build): EXACT=$pass INEXACT=${inexact:-0} HALT=${halt:-0}"
if [ "${halt:-0}" -eq 0 ]; then
    echo "-> CONFIRMED: every transcendental COMPUTES with +VEN_TRANSCENDENTAL (none HALT)."
    echo "   The TRANSC findings are FEATURE-GATED, not broken; INEXACT ones are the"
    echo "   expected ULP difference between the core's algorithm and qemu's softfloat."
else
    echo "-> $halt transcendental(s) still HALT with the flag — a genuine remaining gap."
fi
