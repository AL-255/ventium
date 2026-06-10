#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.7 — Intel 8237A DMA controller (ctrl 0 + page regs) device gate.
#
# FULL PER-RECORD DIFFERENTIAL vs qemu-system-i386, same shape as run-soc-dev-gate:
# the psoc8237 image is entirely SYNCHRONOUS (IN/OUT to 0x00-0x0F + 0x81/0x83/0x87,
# NO interrupts, NO DMA transfer), so gen_trace.py --system single-step is a valid
# per-record oracle and the gate is plain compare.py EQUIVALENT, running on
# ventium_soc (with the M8.7 ven_i8237 DMA controller).
#
# What it proves byte-identical over every retired instruction:
#   * reset: status(0x08)=0x00, mask(0x09)=0xFF
#   * ch0 base ADDRESS + COUNT round-trip via the flip-flop (init_chan on MSB write)
#   * flip-flop clear (0x0C) re-bases the LSB/MSB sequencing
#   * mask via clear-all (0x0E) / single (0x0A) / write-all (0x0F), read at 0x09
#   * page registers 0x81->ch2 / 0x83->ch1 / 0x87->ch0 round-trip
# The actual DMA transfer / DREQ / DACK / TC is an explicit oracle boundary (needs a
# device asserting DREQ + a host-clock loop the single-step golden cannot reproduce,
# like the 8042 OBF boundary); the request register (0x09 W) is never written.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-dma-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psoc8237"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psoc8237.bin"
GOLD_REF="$TDIR/psoc8237.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psoc8237.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psoc8237.rtl.soc.vtrace"
PORT="${PORT:-51154}"
MAXI=250

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build psoc8237.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm psoc8237.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
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

# --- 4. run ventium_soc on psoc8237.bin -----------------------------------------
say "4. run ventium_soc on psoc8237.bin (8237 DMA register surface)"
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
  echo "SOC-DMA-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  8237 ctrl0: reset status/mask + ch0 addr/count flip-flop round-trip +"
  echo "  mask clear/single/write-all + page regs (0x81/0x83/0x87): byte-identical"
  echo "  to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.7 SOC DMA GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.7 SOC DMA GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
