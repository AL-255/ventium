#!/usr/bin/env bash
# capture_qemu_pcs.sh — run qemu-system-i386 (FreeDOS boot, same platform as the
# Ventium RTL SoC) with one-insn-per-tb exec tracing, and compact the huge
# "-d exec,nochain" log on the fly (via a FIFO) into a PC-per-line sequence file.
#
# Output: $PCSEQ — one 8-hex-digit guest *linear* PC per line, in execution order.
#         (The 2nd '/'-field of each "Trace" line is cs_base+eip = linear PC; the
#          first entry is fffffff0 = reset vector, 00007c00 appears at MBR boot.)
#
# Re-runnable; parameterize via env or edit below.
set -u

REPO=${REPO:-/home/yukidama/github/ventium}
QEMU=${QEMU:-$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386}
BIOS=${BIOS:-$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios/bios.bin}
SRC_HDD=${SRC_HDD:-$REPO/ventium-refs/freedos/fd_hdd.img}
HDD=${HDD:-/tmp/f3diff_hdd.img}            # qemu may write; always run on a copy
PCSEQ=${PCSEQ:-/tmp/f3diff_qemu_pcs.txt}   # compact ordered PC stream (output)
FIFO=${FIFO:-/tmp/f3diff_qemu.fifo}
DURATION=${DURATION:-360}                  # seconds of wall-clock qemu time

cp -f "$SRC_HDD" "$HDD"

rm -f "$FIFO" "$PCSEQ"
mkfifo "$FIFO"

# Consumer: keep only Trace lines, print the linear PC (low 8 hex of field 2).
mawk -F/ '/^Trace/ && NF>=4 {print substr($2,9,8)}' < "$FIFO" > "$PCSEQ" &
AWK_PID=$!

timeout "$DURATION" "$QEMU" \
  -M pc -cpu pentium \
  -bios "$BIOS" \
  -drive file="$HDD",format=raw,if=ide \
  -display none -net none -monitor none -serial none \
  -accel tcg,one-insn-per-tb=on \
  -d exec,nochain -D "$FIFO"
RC=$?

wait "$AWK_PID"
rm -f "$FIFO"
echo "qemu exit=$RC (124 = killed by timeout, expected)"
echo "captured $(wc -l < "$PCSEQ") PC entries -> $PCSEQ"
