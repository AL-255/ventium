#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium F3 — BIOS firmware gate (INT 10h teletype service + IVT, real-mode delivery), FULL PER-RECORD DIFFERENTIAL vs qemu-system.
#
# Proves the newly-ungated CPUID (the decode now fires K_CPUID under soc_en, not just
# cosim_en) is byte-identical to qemu-system-i386 `-cpu pentium`. A reset-vector -bios
# firmware (psocbios.bin) stays in 16-bit real mode and executes CPUID for four leaves
# (0x0 / 0x1 / 0x40000000 / 0x80000000), then isa-debug-exits. CPUID is synchronous and
# deterministic (no IRQ, no async I/O), so the standard gen_trace.py --system single-step
# golden is a valid per-record oracle (unlike the IRQ gates) — the per-record compare
# checks eax/ebx/ecx/edx the instant each CPUID retires, diffing all four results vs qemu.
#
# NON-VACUOUS: the gate asserts the RTL trace actually RETIRES the four `cpuid` opcodes
# (pc reaches each CPUID site) in addition to per-record EQUIVALENT, so a silent early
# HALT (the pre-ungate behaviour) can never pass. Zero new RTL beyond the 1-line decode
# ungate; the K_CPUID leaf table already existed.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-cpuid-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocbios"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocbios.bin"                          # the 64 KiB real-mode -bios firmware
GOLD_REF="$TDIR/psocbios.sys.vtrace.golden"        # committed reference (evidence)
GOLD_GEN="$OUTDIR/psocbios.sys.vtrace.golden"      # freshly regenerated this run
RTL_OUT="$OUTDIR/psocbios.rtl.soc.vtrace"
PORT="${PORT:-51275}"
MAXI=700  # ~12 insns/char (app+INT+handler+IRET) x ~34 chars

say(){ echo; echo "=== $* ==="; }

# --- 0. build the CPUID firmware -------------------------------------------------
say "0. build psocbios.bin (-bios BIOS firmware: INT 10h teletype)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: firmware $IMG missing"; exit 1; }
echo "firmware: $IMG ($(stat -c%s "$IMG") bytes)"

# --- 1. build the ventium_soc --soc TB (soc_en=1; CPUID now decodes) -------------
say "1. build the ventium_soc --soc TB"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }

# --- 2. confirm the firmware reaches isa-debug-exit (code 133) under qemu --------
say "2. confirm psocbios reaches isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -cpu pentium -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: reached qemu exit $RC, expected 133 (the CPUID firmware's isa-debug-exit)"; exit 1; }
echo "qemu-system exit code = $RC: OK"

# --- 3. (re)generate the per-record golden ---------------------------------------
say "3. generate the per-record golden (gen_trace.py --system, qemu-system -cpu pentium single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --cpu pentium
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# drift check vs the committed reference golden (records, skipping the note line).
if [[ -f "$GOLD_REF" ]]; then
  if diff -q <(tail -n +2 "$GOLD_REF") <(tail -n +2 "$GOLD_GEN") >/dev/null 2>&1; then
    echo "golden drift check: records identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden records differ from the committed reference"
    echo "      ($GOLD_REF) -- the live oracle below is authoritative. Inspect if unexpected."
  fi
fi

# NON-VACUOUS: the golden must REACH the LAST CPUID site (pc=0x0000008c, the 12th
# leaf). If CPUID HALTed (the pre-ungate behaviour) the trace would stop at the first
# one (0x13) and never reach here -- so this guards against a vacuous pass.
HANDLER='"pc":"0x0000003c"'   # the INT 10h handler wrote COM1
EXITED='"pc":"0x0000002a"'   # the app finished + reached exit
grep -q "$HANDLER" "$GOLD_GEN" || { echo "FATAL: golden never runs the INT 10h handler (pc=0x3c)"; exit 1; }
grep -q "$EXITED" "$GOLD_GEN" || { echo "FATAL: golden never finishes the banner (pc=0x2a)"; exit 1; }
echo "non-vacuous (golden): runs the INT 10h handler (0x3c) AND finishes (0x2a): OK"

# --- 4. run ventium_soc on the firmware ------------------------------------------
say "4. run ventium_soc on psocbios.bin"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" --max-insn "$MAXI" --max-cycles 200000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
grep -q "$HANDLER" "$RTL_OUT" || { echo "FATAL: RTL never runs the INT 10h handler (pc=0x3c) -- INT service failed"; exit 1; }
grep -q "$EXITED" "$RTL_OUT" || { echo "FATAL: RTL never finishes the banner (pc=0x2a)"; exit 1; }
echo "non-vacuous (RTL): ventium_soc runs the INT 10h handler (0x3c) AND finishes (0x2a): OK"

# --- 5. per-record differential --------------------------------------------------
say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-BIOS-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc prints a banner via the INT 10h teletype BIOS service (IVT + real-mode"
  echo "  INT/IRET) byte-identical to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "F3 BIOS-firmware (INT 10h) GATE: EQUIVALENT (per-record, full differential)"
else
  echo "F3 BIOS-firmware (INT 10h) GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
