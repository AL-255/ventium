#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.5 — COM1 UART (NS16550A) device gate.
#
# FULL PER-RECORD DIFFERENTIAL vs qemu-system-i386, same shape as run-soc-dev-gate:
# the psocuart image is entirely SYNCHRONOUS (IN/OUT to 0x3F8..0x3FF, NO interrupts),
# so gen_trace.py --system single-step is a valid per-record oracle and the gate is
# plain compare.py EQUIVALENT, running on ventium_soc (with the M8.5 UART).
#
# What it proves byte-identical over every retired instruction:
#   * reset LSR = 0x60 (TEMT|THRE), reset IIR = 0x01 (NO_INT)
#   * SCR (full byte), LCR (full), IER (mask 0x0F), MCR (mask 0x1F) round-trips
#   * divisor-latch DLL/DLM banking via LCR.DLAB
#   * IIR FIFO-enabled bits after FCR.bit0 (0xC1)
#   * THR write accepted (no HALT)
# The async RX / loopback / MSR / IRQ4 paths are an explicit oracle boundary (qemu
# drives them off a host chardev + transmit timer the single-step golden cannot
# reproduce — like the 8042 OBF boundary); covered by the board/unit path.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-uart-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocuart"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocuart.bin"
GOLD_REF="$TDIR/psocuart.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/psocuart.sys.vtrace.golden"
RTL_OUT="$OUTDIR/psocuart.rtl.soc.vtrace"
PORT="${PORT:-51126}"
MAXI=250

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build psocuart.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm psocuart.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
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

# --- 4. run ventium_soc on psocuart.bin -----------------------------------------
say "4. run ventium_soc on psocuart.bin (COM1 UART register surface)"
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
  echo "SOC-UART-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  NS16550A COM1: reset LSR/IIR + SCR/LCR/IER/MCR round-trips + DLAB"
  echo "  divisor banking + FCR->IIR FIFO bits + THR-write acceptance: byte-"
  echo "  identical to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.5 SOC UART GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.5 SOC UART GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
