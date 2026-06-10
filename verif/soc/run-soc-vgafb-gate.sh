#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.6 — VGA mode-13h CHAIN-4 framebuffer (0xA0000) device gate.
#
# FULL PER-RECORD DIFFERENTIAL vs qemu-system-i386, same shape as run-soc-dev-gate:
# the pvgafb image is entirely SYNCHRONOUS (VGA mode-set IN/OUT + chain-4 linear
# memory writes/reads, NO interrupts), so gen_trace.py --system single-step is a
# valid per-record oracle (compare.py grades GPRs per retired instruction, so a
# load of a written pixel into a GPR is directly diffable) and the gate is plain
# compare.py EQUIVALENT, running on ventium_soc (with the M8.6 ven_vga_fb VRAM).
#
# What it proves byte-identical over every retired instruction:
#   * the 0xA0000 window is recognised as VRAM (writes land, reads return them)
#   * chain-4 LINEAR identity: a byte written at 0xA0000+N reads back at +N
#   * per-byte PLANE GATING: with SR2 != 0x0F, a write lands only in the enabled
#     plane lanes; masked lanes keep their prior value EXACTLY as qemu (the case a
#     plain-RAM 0xA0000 gets WRONG — the reason the dedicated VRAM module exists)
# The scan-out / pixel rendering / DAC palette expansion, and the planar/latched
# write-modes are an explicit oracle boundary (the PS A53 owns scan-out on the
# board); the test sets chain-4 FIRST and never touches 0xA0000 before (contract).
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-vgafb-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/pvgafb"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/pvgafb.bin"
GOLD_REF="$TDIR/pvgafb.sys.vtrace.golden"
GOLD_GEN="$OUTDIR/pvgafb.sys.vtrace.golden"
RTL_OUT="$OUTDIR/pvgafb.rtl.soc.vtrace"
PORT="${PORT:-51128}"
MAXI=250

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build pvgafb.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm pvgafb.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
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

# --- 4. run ventium_soc on pvgafb.bin -----------------------------------------
say "4. run ventium_soc on pvgafb.bin (VGA chain-4 framebuffer (0xA0000))"
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
  echo "SOC-VGAFB-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  VGA mode-13h chain-4 VRAM @ 0xA0000: linear write/read-back identity +"
  echo "  per-byte SR2 plane gating (masked lanes keep prior value): byte-identical"
  echo "  to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.6 SOC VGA-FB GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.6 SOC VGA-FB GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
