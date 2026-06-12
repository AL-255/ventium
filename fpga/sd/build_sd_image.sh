#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/sd/build_sd_image.sh — assemble a flashable KV260 microSD boot image from a
# Ventium .xsa + .bit. Produces, under $OUT:
#   boot/BOOT.BIN      FSBL + PMUFW + bitstream + ven_boot.elf  (bootgen, ZynqMP)
#   ventium_kv260_sd.img   MBR + one FAT32 partition holding BOOT.BIN  (dd to an SD card)
#
# Everything runs without root: mtools (mformat/mcopy) format + populate the FAT32
# partition in-place at its byte offset inside the image file.
#
# Boot the KV260 with the SOM boot-mode switch set to SD, a serial console on UART1
# (MIO36/37, 115200 8N1), and this image dd'd to the card:  dd if=ventium_kv260_sd.img
# of=/dev/sdX bs=4M conv=fsync   (replace sdX with the card device — DOUBLE-CHECK it).
#
# Usage:
#   fpga/sd/build_sd_image.sh <build_tag>
#     build_tag: the impl OUTTAG, e.g. _f3 -> fpga/build/kv260_soc_impl_f3/{ventium_kv260.xsa,.bit}
#   or explicitly:  XSA=path BIT=path OUT=dir fpga/sd/build_sd_image.sh
#
# Env knobs: IMG_MB (image size, default 128), REUSE_SW=1 (skip FSBL/PMUFW/BSP regen if
# already present — valid only when the PS config is unchanged).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SD="$ROOT/fpga/sd"
VITIS=/tools/Xilinx/2025.2/Vitis
XSCT="$VITIS/bin/xsct"
BOOTGEN="$VITIS/bin/bootgen"
TOOLCHAIN="$VITIS/gnu/aarch64/lin/aarch64-none/bin"
PSOCFW="$ROOT/verif/sys/tests/psocfw/psocfw.bin"
IMG_MB="${IMG_MB:-128}"

# ---- resolve inputs --------------------------------------------------------------
TAG="${1:-}"
if [[ -n "$TAG" ]]; then
    BDIR="$ROOT/fpga/build/kv260_soc_impl${TAG}"
    XSA="${XSA:-$BDIR/ventium_kv260.xsa}"
    BIT="${BIT:-$BDIR/ventium_kv260.bit}"
    OUT="${OUT:-$BDIR/sd}"
fi
: "${XSA:?set XSA or pass a build tag}"; : "${BIT:?set BIT or pass a build tag}"; : "${OUT:?set OUT or pass a build tag}"
[[ -f "$XSA" ]]    || { echo "FATAL: no .xsa at $XSA"; exit 1; }
[[ -f "$BIT" ]]    || { echo "FATAL: no .bit at $BIT"; exit 1; }
[[ -f "$PSOCFW" ]] || { echo "FATAL: no psocfw payload at $PSOCFW"; exit 1; }
[[ -x "$XSCT" ]]   || { echo "FATAL: no xsct at $XSCT"; exit 1; }
mkdir -p "$OUT"
XSA="$(readlink -f "$XSA")"; BIT="$(readlink -f "$BIT")"

echo "=== Ventium KV260 SD image build ==="
echo "  XSA = $XSA"
echo "  BIT = $BIT  ($(stat -c %s "$BIT") bytes)"
echo "  OUT = $OUT"

# ---- 1. FSBL + PMUFW + app BSP (xsct) --------------------------------------------
if [[ "${REUSE_SW:-0}" == "1" && -f "$OUT/fsbl/executable.elf" && -f "$OUT/pmufw/executable.elf" \
      && -n "$(ls "$OUT"/app/*_bsp/psu_cortexa53_0/lib/libxil.a 2>/dev/null)" ]]; then
    echo "=== [1/5] reuse existing FSBL/PMUFW/BSP (REUSE_SW=1) ==="
else
    echo "=== [1/5] generate FSBL + PMUFW + app BSP (xsct) ==="
    "$XSCT" "$SD/gen_boot_artifacts.tcl" "$XSA" "$OUT" 2>&1 | \
        grep -vE 'XSCT is deprecated|vitis -|Run "|We recommend|^\s*$' | tail -40
fi
FSBL="$OUT/fsbl/executable.elf"
PMUFW="$OUT/pmufw/executable.elf"
APPDIR="$(dirname "$(ls "$OUT"/app/*_bsp/psu_cortexa53_0/lib/libxil.a)")/../../.."
APPDIR="$(readlink -f "$APPDIR")"
[[ -f "$FSBL" && -f "$PMUFW" ]] || { echo "FATAL: FSBL/PMUFW not generated"; exit 1; }

# ---- 2. embed psocfw + build ven_boot.elf ----------------------------------------
echo "=== [2/5] build ven_boot.elf (embed psocfw, link against BSP) ==="
# clean any prior app sources, drop ours in
rm -f "$APPDIR"/*.c "$APPDIR"/*.o "$APPDIR"/executable.elf
cp "$SD/ven_boot/ven_boot.c"                "$APPDIR/"
cp "$ROOT/sw/ps/ven_soc_app/ven_soc_regs.h" "$APPDIR/"
( cd "$ROOT" && xxd -i -n psocfw_bin "$PSOCFW" ) | \
    sed 's/unsigned int psocfw_bin_len/unsigned psocfw_bin_len/' > "$APPDIR/psocfw_payload.h"
echo "  psocfw_payload.h: $(wc -l < "$APPDIR/psocfw_payload.h") lines"
PATH="$TOOLCHAIN:$PATH" make -C "$APPDIR" clean >/dev/null 2>&1 || true
PATH="$TOOLCHAIN:$PATH" make -C "$APPDIR" 2>&1 | tail -8
APPELF="$APPDIR/executable.elf"
[[ -f "$APPELF" ]] || { echo "FATAL: ven_boot.elf not built"; exit 1; }
echo "  ven_boot.elf: $(stat -c %s "$APPELF") bytes"

# ---- 3. bootgen BOOT.BIN ----------------------------------------------------------
echo "=== [3/5] bootgen BOOT.BIN ==="
mkdir -p "$OUT/boot"
cat > "$OUT/boot/boot.bif" <<EOF
the_ROM_image:
{
    [bootloader, destination_cpu=a53-0] $FSBL
    [pmufw_image] $PMUFW
    [destination_device=pl] $BIT
    [destination_cpu=a53-0] $APPELF
}
EOF
"$BOOTGEN" -arch zynqmp -image "$OUT/boot/boot.bif" -o "$OUT/boot/BOOT.BIN" -w on 2>&1 | tail -4
[[ -f "$OUT/boot/BOOT.BIN" ]] || { echo "FATAL: BOOT.BIN not generated"; exit 1; }
echo "  BOOT.BIN: $(stat -c %s "$OUT/boot/BOOT.BIN") bytes"

# ---- 4. FAT32 partitioned SD image (root-free, mtools) ---------------------------
echo "=== [4/5] FAT32 SD image (${IMG_MB} MiB) ==="
IMG="$OUT/ventium_kv260_sd.img"
PART_OFF=$((1024*1024))          # partition starts at 1 MiB (sector 2048)
rm -f "$IMG"
truncate -s "$((IMG_MB*1024*1024))" "$IMG"
sfdisk "$IMG" >/dev/null 2>&1 <<EOF
label: dos
unit: sectors
start=2048, type=c, bootable
EOF
# format + populate the partition in-place at its byte offset
MTOOLS_SKIP_CHECK=1 mformat -i "$IMG@@${PART_OFF}" -F -v VENTIUM ::
MTOOLS_SKIP_CHECK=1 mcopy   -i "$IMG@@${PART_OFF}" "$OUT/boot/BOOT.BIN" ::BOOT.BIN
echo "  partition contents:"
MTOOLS_SKIP_CHECK=1 mdir -i "$IMG@@${PART_OFF}" :: | sed 's/^/    /'

# ---- 5. summary -------------------------------------------------------------------
echo "=== [5/5] DONE ==="
echo "  BOOT.BIN : $OUT/boot/BOOT.BIN"
echo "  SD image : $IMG  ($(stat -c %s "$IMG") bytes)"
echo "  Flash    : dd if=$IMG of=/dev/sdX bs=4M conv=fsync   (verify sdX!)"
echo "BUILD_SD_IMAGE_OK"
