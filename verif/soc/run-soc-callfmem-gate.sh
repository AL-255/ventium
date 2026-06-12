#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — SoC real-mode FAR INDIRECT CALL (FF /3) + FAR INDIRECT JMP (FF /5) gate,
# FULL PER-RECORD DIFFERENTIAL vs qemu-system. These memory-indirect far-transfer
# forms were added recently and had NO gate (only direct 9A CALLF / CB RETF, M9.5).
# A reset-vector -bios firmware stays in 16-bit real mode and exercises, through
# far-pointer tables in memory:
#   A: call far [bx]      (FF 1F,    mod=00 rm=111, DS default)
#   B: call far [bp+8]    (FF 5E 08, mod=01 rm=110, SS DEFAULT segment)
#   C: call far [disp16]  (FF 1E,    mod=00 rm=110, DS default)
#   D: call far [bx+si]   (FF 18,    mod=00 rm=000, two-component EA + decoy entry)
#   E: NESTED far indirect call (outer callee far-indirect-calls an inner callee)
#   F: jmp far [bx]       (FF 2F)    -> landing pad (fall-through = hlt trap)
#   G: jmp far [bp+6]     (FF 6E 06, SS default) -> landing pad (fall-through = trap)
# Every callee RETFs; the instruction after each return captures SP into a register
# so push/pop width or SP-delta errors show in the per-record register diff. All
# transfers are synchronous + deterministic, so the gen_trace.py --system single-
# step golden is a valid per-record oracle (compare.py --mode func).
#
# NON-VACUOUS: the gate asserts BOTH traces produce every callee/landing-pad CX
# marker (0x1111..0x8888 incl. the nested 0x6655/0x6666) AND reach the final
# landmark pc (`done`, computed live from the ELF) -- a silent HALT or a no-op
# transfer (the far-JMP fall-throughs are distinct-marker hlt traps) reaches neither.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-callfmem-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psoccallfmem"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psoccallfmem.bin"
ELF="$TDIR/psoccallfmem.elf"
GOLD_REF="$TDIR/psoccallfmem.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psoccallfmem.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psoccallfmem.rtl.soc.vtrace"
PORT="${PORT:-51299}"
MAXI=90

# Callee / landing-pad CX markers (each unique to one far transfer's target):
MARKERS=(
  '"ecx":"0x00001111"'   # calleeA  (call far [bx])
  '"ecx":"0x00002222"'   # calleeB  (call far [bp+8], SS default)
  '"ecx":"0x00003333"'   # calleeC  (call far [disp16])
  '"ecx":"0x00004444"'   # calleeD  (call far [bx+si], decoy-guarded)
  '"ecx":"0x00005555"'   # calleeEo (nested outer entered)
  '"ecx":"0x00006666"'   # calleeEi (nested inner entered)
  '"ecx":"0x00006655"'   # calleeEo resumed after inner RETF
  '"ecx":"0x00007777"'   # landF    (jmp far [bx] landed)
  '"ecx":"0x00008888"'   # landG    (jmp far [bp+6] landed)
)

say(){ echo; echo "=== $* ==="; }

say "0. build psoccallfmem.bin (-bios real-mode far-indirect CALL/JMP firmware)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: firmware $IMG missing"; exit 1; }
echo "firmware: $IMG ($(stat -c%s "$IMG") bytes)"

# Final landmark pc, computed live from the ELF (done = the post-landG exit block).
DONE_SYM="$(nm "$ELF" | awk '$3=="done_off"{print $1}')"
[[ -n "$DONE_SYM" ]] || { echo "FATAL: done_off symbol missing from $ELF"; exit 1; }
DONE_PC="$(printf '"pc":"0x%08x"' $((16#$DONE_SYM)))"
echo "final landmark: done @ F000:0x${DONE_SYM#0000} -> $DONE_PC"

say "1. build the ventium_soc --soc TB"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }

say "2. confirm psoccallfmem reaches isa-debug-exit (code 133) under qemu-system-i386"
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
for kv in "${MARKERS[@]}"; do
  grep -q "$kv" "$GOLD_GEN" || { echo "FATAL: golden missing far-transfer marker $kv"; exit 1; }
done
grep -q "$DONE_PC" "$GOLD_GEN" || { echo "FATAL: golden never reaches the final landmark $DONE_PC"; exit 1; }
echo "non-vacuous (golden): all 9 far-transfer markers + final landmark pc present: OK"

say "4. run ventium_soc on psoccallfmem.bin"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" --max-insn "$MAXI" --max-cycles 200000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
for kv in "${MARKERS[@]}"; do
  grep -q "$kv" "$RTL_OUT" || { echo "FATAL: RTL missing far-transfer marker $kv -- that FF /3 / FF /5 form failed"; exit 1; }
done
grep -q "$DONE_PC" "$RTL_OUT" || { echo "FATAL: RTL never reaches the final landmark $DONE_PC"; exit 1; }
echo "non-vacuous (RTL): ventium_soc produced all 9 far-transfer markers + final landmark pc: OK"

say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-CALLFMEM-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc executes real-mode far INDIRECT CALL (FF /3 via [bx], [bp+8] SS-"
  echo "  default, [disp16], [bx+si], nested) + far INDIRECT JMP (FF /5 via [bx], [bp+6])"
  echo "  byte-identical to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "SoC far indirect CALL/JMP (FF /3, FF /5) GATE: EQUIVALENT (per-record, full differential)"
else
  echo "SoC far indirect CALL/JMP (FF /3, FF /5) GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
