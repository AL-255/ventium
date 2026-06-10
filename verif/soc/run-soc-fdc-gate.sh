#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.9 — 82077 floppy disk controller device gate.
#
# FULL PER-RECORD DIFFERENTIAL vs qemu-system-i386, same shape as run-soc-dev-gate:
# the psocfdc image is entirely SYNCHRONOUS (FDC register IN/OUT to 0x3F0-0x3F5 +
# 0x3F7, NO disk, NO DMA, NO seek timing, NO interrupts taken), so gen_trace.py
# --system single-step is a valid per-record oracle and the gate is plain
# compare.py EQUIVALENT, running on ventium_soc (with the M8.9 ven_i8272 FDC).
#
# What it proves byte-identical over every retired instruction:
#   * DOR (0x3F2) software reset + read-back (0x0C = dor|cur_drv)
#   * the MSR (0x3F4) RQM/DIO/CB command-FIFO handshake: 0x80 ready -> 0xD0 result
#   * post-reset SENSE INTERRUPT 4-drive polling (ST0 = 0xC0/0xC1/0xC2/0xC3, PCN=0)
#   * VERSION (0x90), PART ID (0x41), LOCK on/off (0x10/0x00)
#   * SPECIFY / CONFIGURE / PERPENDICULAR (no-result commands -> MSR back to 0x80)
# The disk READ/WRITE/FORMAT/READ-ID + RECALIBRATE/SEEK (async seek timing + IRQ)
# + the DIR media-change bit are the oracle boundary (need disk/DMA or a host-clock
# timer the single-step golden cannot reproduce); the IRQ6 on reset-release is
# quiescent on the diff (CLI).
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-fdc-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocfdc"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocfdc.bin"
GOLD_REF="$TDIR/psocfdc.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psocfdc.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psocfdc.rtl.soc.vtrace"
PORT="${PORT:-51162}"
MAXI=250

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build psocfdc.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm psocfdc.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing (run verif/sys/build-qemu-system.sh)"; exit 1; }
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: image reached qemu exit $RC, expected 133"; exit 1; }
echo "qemu-system exit code = $RC (isa-debug-exit 0x42 -> (0x42<<1)|1 = 133): OK"

# --- 3. (re)generate the per-record golden --------------------------------------
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI"
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

if [[ -f "$GOLD_REF" ]]; then
  if diff -q "$GOLD_REF" "$GOLD_GEN" >/dev/null 2>&1; then
    echo "golden drift check: identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden differs from the committed reference"
    echo "      ($GOLD_REF) — qemu/host detail changed; the live oracle below is"
    echo "      authoritative. Inspect if unexpected."
  fi
fi

# --- 4. run ventium_soc on psocfdc.bin -----------------------------------------
say "4. run ventium_soc on psocfdc.bin (FDC register surface)"
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
  echo "SOC-FDC-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  82077 FDC: DOR reset + read-back, MSR RQM/DIO/CB handshake, post-reset"
  echo "  SENSE INTERRUPT polling (0xC0-0xC3), VERSION/PART-ID/LOCK, SPECIFY/"
  echo "  CONFIGURE/PERPENDICULAR: byte-identical to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) records."
  echo
  echo "M8.9 SOC FDC GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.9 SOC FDC GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
