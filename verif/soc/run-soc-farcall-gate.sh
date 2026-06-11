#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M9.5 — SoC real-mode far CALL (0x9A) + RETF (0xCB) gate, FULL PER-RECORD
# DIFFERENTIAL vs qemu-system. A reset-vector -bios firmware stays in 16-bit real mode,
# far-CALLs a routine in segment F000, the routine RETFs back, then isa-debug-exits.
# Both transfers are synchronous + deterministic, so the gen_trace.py --system single-
# step golden is a valid per-record oracle: compare.py --mode func checks CS/EIP/ESP and
# the pushed stack at each step, diffing the far CALL push (CS:IP) and the RETF pop vs
# qemu over every retired instruction.
#
# NON-VACUOUS: the gate asserts the RTL trace REACHES the called routine (pc=0x1e, the
# far CALL landed) AND RETURNS to the call site (pc=0x12, the RETF popped back) -- a
# silent HALT (the pre-implementation behaviour) reaches neither.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-farcall-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocfarcall"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocfarcall.bin"
GOLD_REF="$TDIR/psocfarcall.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psocfarcall.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psocfarcall.rtl.soc.vtrace"
PORT="${PORT:-51270}"
MAXI=40
CALLED='"pc":"0x0000001e"'   # the far-called routine (the CALL landed)
RETURNED='"pc":"0x00000012"' # the call site (the RETF popped back)

say(){ echo; echo "=== $* ==="; }

say "0. build psocfarcall.bin (-bios real-mode far CALL / RETF firmware)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: firmware $IMG missing"; exit 1; }
echo "firmware: $IMG ($(stat -c%s "$IMG") bytes)"

say "1. build the ventium_soc --soc TB"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }

say "2. confirm psocfarcall reaches isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -cpu pentium -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: reached qemu exit $RC, expected 133"; exit 1; }
echo "qemu-system exit code = $RC: OK"

say "3. generate the per-record golden (gen_trace.py --system, qemu-system -cpu pentium single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --cpu pentium
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"
if [[ -f "$GOLD_REF" ]]; then
  if diff -q <(tail -n +2 "$GOLD_REF") <(tail -n +2 "$GOLD_GEN") >/dev/null 2>&1; then
    echo "golden drift check: records identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden records differ from the committed reference (live oracle authoritative)"
  fi
fi
grep -q "$CALLED"   "$GOLD_GEN" || { echo "FATAL: golden never reaches the far-called routine (pc=0x1e)"; exit 1; }
grep -q "$RETURNED" "$GOLD_GEN" || { echo "FATAL: golden never returns to the call site (pc=0x12)"; exit 1; }
echo "non-vacuous (golden): reaches the called routine (0x1e) AND returns (0x12): OK"

say "4. run ventium_soc on psocfarcall.bin"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" --max-insn "$MAXI" --max-cycles 200000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
grep -q "$CALLED"   "$RTL_OUT" || { echo "FATAL: RTL never reaches the far-called routine (pc=0x1e) -- far CALL failed"; exit 1; }
grep -q "$RETURNED" "$RTL_OUT" || { echo "FATAL: RTL never returns to the call site (pc=0x12) -- RETF failed"; exit 1; }
echo "non-vacuous (RTL): ventium_soc reaches the routine (0x1e) AND returns (0x12): OK"

say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-FARCALL-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc executes real-mode far CALL (0x9A, push CS:IP) + RETF (0xCB, pop"
  echo "  CS:IP) byte-identical to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M9.5 SoC far CALL / RETF GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M9.5 SoC far CALL / RETF GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
