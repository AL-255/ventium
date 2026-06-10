#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — PS-OFFLOAD peripheral cosim gate. Proves a PS-placed peripheral's C
# model (sw/ps_periph/<model>.c) is bit-exact vs qemu-system, by building
# ventium_soc with +VEN_<DEV>_PS (the device is then NOT in RTL — its I/O port
# range is forwarded over the io-bridge to the C model in tb_soc, exactly as it
# would be to the A53 on the board) and running the SAME psoc<dev> per-record test
# the all-RTL gate uses. EQUIVALENT here == the C model == the RTL module == qemu.
#
# Usage: bash verif/soc/run-soc-ps-cosim-gate.sh <dev>   (dev: uart | rtc | ... )
set -euo pipefail
DEV="${1:-uart}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# dev -> (PS define, test name). Extend as C models land.
case "$DEV" in
  uart) DEFINE=VEN_UART_PS;   TEST=psocuart ;;
  rtc)  DEFINE=VEN_RTC_PS;    TEST=psocdev  ;;
  *) echo "unknown dev '$DEV' (uart|rtc|...)"; exit 2 ;;
esac

QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"
TDIR="$REPO/verif/sys/tests/$TEST"
OUTDIR="$REPO/build/soc"; mkdir -p "$OUTDIR"
IMG="$TDIR/$TEST.bin"
GOLD="$TDIR/$TEST.sys.vtrace.golden"
RTL="$OUTDIR/$TEST.ps_$DEV.vtrace"
OBJ="obj_dir_soc_${DEV}ps"
say(){ echo; echo "=== $* ==="; }

say "1. build $TEST image + the +$DEFINE ventium_soc TB (the '$DEV' served by its C model)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: $IMG missing"; exit 1; }
make -C "$REPO/verif/tb" soc SOC_OBJDIR="$OBJ" VL_EXTRA_DEFINES="+define+$DEFINE" >/dev/null 2>&1
TB="$REPO/verif/tb/$OBJ/tb_soc"
[[ -x "$TB" ]] || { echo "FATAL: PS-cosim TB $TB not built"; exit 1; }
echo "PS-cosim TB ($DEV served by sw/ps_periph C model): $TB"

say "2. confirm $IMG reaches isa-debug-exit (133) under qemu-system-i386"
set +e; timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" == "133" ]] || { echo "FATAL: qemu exit $RC (expected 133)"; exit 1; }

say "3. per-record golden (gen_trace.py --system)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$OUTDIR/$TEST.golden" --port "${PORT:-51170}" --max-insn 300
echo "golden: $OUTDIR/$TEST.golden ($(wc -l < "$OUTDIR/$TEST.golden") lines)"

say "4. run the PS-cosim TB ($DEV forwarded to its C model) on $TEST"
"$TB" --image "$IMG" --out "$RTL" --max-insn 300 --max-cycles 20000000 --quiesce 300
echo "trace: $RTL ($(wc -l < "$RTL") lines)"

say "5. per-record differential (compare.py --mode func): golden vs PS-cosim"
set +e; "$PY" "$REPO/verif/diff/compare.py" --mode func "$OUTDIR/$TEST.golden" "$RTL"; CMP=$?; set -e
echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-PS-COSIM-OK ($DEV)  — the C model sw/ps_periph is byte-identical to"
  echo "  qemu-system-i386 over all $(($(wc -l < "$RTL")-1)) retired instructions"
  echo "  (PS-placed: served via the io-bridge C dispatch, NOT the RTL module)."
  echo
  echo "PS-OFFLOAD COSIM GATE ($DEV): EQUIVALENT (C model == RTL == qemu)"
else
  echo "PS-OFFLOAD COSIM GATE ($DEV): FAIL (compare.py exit $CMP)"; exit 1
fi
