#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium F3 — real-mode EXCEPTION (#DE) IVT delivery gate, FULL PER-RECORD DIFFERENTIAL vs qemu-system.
#
# Directed validation of the start_fault(real_mode ? S_RMINT_RD : S_INT_GATE) fix: a
# pure real-mode (PE=0) hardware exception must vector through the 4-byte IVT, not the
# protected-mode 8-byte gate. Unlike a maskable IRQ (nondeterministic boundary, needs a
# LAPIC unreachable in real mode), a #DE is SYNCHRONOUS — the gdbstub single-step masks
# only INTR/timer (NOIRQ|NOTIMER), never exceptions — so this is a clean per-record
# differential exactly like psocrmint, no structural-boundary handling needed.
#
# The firmware (psocrmexc.bin) installs IVT[0] (#DE) @ 0:0 = {handler, 0xF000}, DIVWs by
# a memory divisor set to 0 -> #DE -> the core delivers through the IVT (pushes FLAGS:CS:IP
# of the FAULTING div, loads CS:IP from IVT[0], clears IF/TF). The handler sets the divisor
# nonzero and IRETs; the fault restart re-executes the div (now succeeding) and falls
# through to isa-debug-exit. The per-record diff checks the whole sequence vs qemu-system.
#
# NON-VACUOUS: the RTL trace MUST reach the handler (EBX=0x2222) AND resume past the div
# (ECX=0x3333). If start_fault regressed (real-mode fault -> the PM gate), delivery would
# walk a garbage IDT/#NP-hang and never set those markers -> the gate fails loudly.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-rmexc-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocrmexc"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocrmexc.bin"
GOLD_REF="$TDIR/psocrmexc.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psocrmexc.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psocrmexc.rtl.soc.vtrace"
PORT="${PORT:-51288}"
MAXI=60

say(){ echo; echo "=== $* ==="; }

say "0. build psocrmexc.bin (-bios real-mode #DE firmware)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: firmware $IMG missing"; exit 1; }
echo "firmware: $IMG ($(stat -c%s "$IMG") bytes)"

say "1. build the ventium_soc --soc TB"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }

say "2. confirm psocrmexc reaches isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -cpu pentium -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: reached qemu exit $RC, expected 133"; exit 1; }
echo "qemu-system exit code = $RC: OK"

say "3. generate the per-record golden (gen_trace.py --system single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --cpu pentium
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

if [[ -f "$GOLD_REF" ]]; then
  if diff -q <(tail -n +2 "$GOLD_REF") <(tail -n +2 "$GOLD_GEN") >/dev/null 2>&1; then
    echo "golden drift check: records identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden records differ from committed $GOLD_REF -- live oracle below is authoritative."
  fi
fi

# NON-VACUOUS (golden): the #DE must have DELIVERED (handler ran -> EBX=0x2222) and
# the fault-restart must have RESUMED past the div (ECX=0x3333).
grep -q '"ebx":"0x00002222"' "$GOLD_GEN" || { echo "FATAL: golden never reaches the #DE handler (EBX=0x2222)"; exit 1; }
grep -q '"ecx":"0x00003333"' "$GOLD_GEN" || { echo "FATAL: golden never resumes past the div (ECX=0x3333)"; exit 1; }
echo "non-vacuous (golden): #DE delivered (EBX=0x2222) + resumed (ECX=0x3333): OK"

say "4. run ventium_soc on psocrmexc.bin"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" --max-insn "$MAXI" --max-cycles 200000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
grep -q '"ebx":"0x00002222"' "$RTL_OUT" || { echo "FATAL: RTL never reaches the #DE handler (EBX=0x2222) -- real-mode fault delivery broken"; exit 1; }
grep -q '"ecx":"0x00003333"' "$RTL_OUT" || { echo "FATAL: RTL never resumes past the div (ECX=0x3333)"; exit 1; }
echo "non-vacuous (RTL): ventium_soc delivered the #DE via the IVT + resumed: OK"

say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-RMEXC-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc delivers a real-mode #DE through the 4-byte IVT (frame push, CS:IP"
  echo "  vector load, IF/TF clear, no error code), the handler runs, IRET resumes the"
  echo "  faulting div, byte-identical to qemu-system-i386 over all retired instructions."
  echo
  echo "F3 real-mode hardware-exception (#DE) IVT GATE: EQUIVALENT (per-record)"
else
  echo "F3 real-mode #DE GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
