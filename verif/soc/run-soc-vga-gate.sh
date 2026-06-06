#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.3 — SoC VGA-register-file gate (VGA 0x3B0..0x3DF + ACPI PM 0x608).
#
# FULL PER-RECORD DIFFERENTIAL — like the M8.2 psocdev gate. Every interaction is
# a SYNCHRONOUS IN/OUT (no interrupts), so the standard gen_trace.py --system
# single-step golden is a valid PER-RECORD oracle and the gate is plain
# compare.py EQUIVALENT — running on ventium_soc (with the M8.3 devices) instead
# of ventium_top.
#
# What it proves, byte-identical to qemu-system-i386 8.2.2 over every retired
# instruction:
#   * VGA register file : MISC/ST00 reset reads; SEQUENCER + GRAPHICS per-index
#     write masks; the DAC 3-byte palette write + read auto-increment; the
#     ATTRIBUTE index/data flip-flop + per-index masks; the MISC color/mono port
#     aliasing (write 0x3c2 bit0 flips which of 0x3b0..0x3bf / 0x3d0..0x3df read
#     0xff); CRTC index/data in BOTH the color (0x3d4/0x3d5) and mono
#     (0x3b4/0x3b5) banks; the CRTC CR0-7 write-lock (CR11 bit7) incl. the
#     CR7-bit4-always-writable case; and the IS1 dumb-retrace toggle
#     (0x3da/0x3ba reads alternate 0x09/0x00, verified deterministic).
#   * ACPI PM (0x608) : the write-inert OUT (a no-op in BOTH qemu — PM region
#     disabled / unassigned-write-ignored — and the RTL — acpi_pm_tmr_write does
#     nothing). The PM VALUE-read is a documented oracle boundary (host-clock-
#     derived + PM region disabled in qemu's default -machine pc) covered by the
#     standalone ven_acpipm unit self-check; this gate never READS 0x608.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-vga-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/pvga"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/pvga.bin"
GOLD_REF="$TDIR/pvga.sys.vtrace.golden"     # committed reference (evidence)
GOLD_GEN="$OUTDIR/pvga.sys.vtrace.golden"   # freshly regenerated this run
RTL_OUT="$OUTDIR/pvga.rtl.soc.vtrace"
PORT="${PORT:-51190}"
MAXI=400

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build pvga.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm pvga.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing (run verif/sys/build-qemu-system.sh)"; exit 1; }
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: image reached qemu exit $RC, expected 133"; exit 1; }
echo "qemu-system exit code = $RC (isa-debug-exit 0x42 -> (0x42<<1)|1 = 133): OK"

# --- 3. (re)generate the per-record golden (authoritative single-step oracle) ---
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI"
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# drift check vs the committed reference golden (evidence artifact must not rot)
if [[ -f "$GOLD_REF" ]]; then
  if diff -q "$GOLD_REF" "$GOLD_GEN" >/dev/null 2>&1; then
    echo "golden drift check: identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden differs from the committed reference"
    echo "      ($GOLD_REF) — qemu/host detail changed; the live oracle below is"
    echo "      authoritative. Inspect if unexpected."
  fi
fi

# --- 4. run ventium_soc on pvga.bin ---------------------------------------------
say "4. run ventium_soc on pvga.bin (VGA register file + ACPI PM write-inert)"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" \
    --max-insn "$MAXI" --max-cycles 20000000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"

# --- 5. per-record differential -------------------------------------------------
say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-VGA-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  VGA register file (MISC/SEQ/GFX/DAC/ATTR/CRTC/IS1 + masks + color/mono"
  echo "  aliasing + CR0-7 lock) + ACPI PM write-inert: byte-identical to"
  echo "  qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.3 SOC VGA GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.3 SOC VGA GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
