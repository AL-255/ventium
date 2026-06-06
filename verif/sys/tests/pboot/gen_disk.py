#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Ventium M9 boot — single-source-of-truth disk image generator.

The boot disk: LBA0 is the BOOT SECTOR (pboot_mbr.bin, ending in 0x55 0xAA), and
every later sector is zero. Emits BOTH artifacts from ONE in-memory byte buffer,
so the qemu-system backing image and the RTL backing store CANNOT drift:

  * pboot.img       -> qemu-system via `-drive if=ide,format=raw,index=0,file=...`
  * pboot.disk.hex  -> ven_ide via `$readmemh` (one byte/line, ascending offset)

Geometry: 128 sectors * 512 B = 64 KiB, matching ven_ide's DISK_SECTORS=128 /
2/16/63 (so the IDENTIFY geometry words and the image size never disagree). The
firmware stub reads only LBA0; the rest is zero (unread).

Usage:
  gen_disk.py --mbr pboot_mbr.bin --img pboot.img --hex pboot.disk.hex
  gen_disk.py --check --mbr pboot_mbr.bin --img pboot.img --hex pboot.disk.hex
"""
import argparse
import sys

DISK_SECTORS = 128
SECTOR_BYTES = 512


def build_disk(mbr_path):
    buf = bytearray(DISK_SECTORS * SECTOR_BYTES)      # all zero
    with open(mbr_path, "rb") as f:
        mbr = f.read()
    if len(mbr) != SECTOR_BYTES:
        sys.stderr.write("FATAL: %s is %d bytes, want exactly %d (one sector)\n"
                         % (mbr_path, len(mbr), SECTOR_BYTES))
        sys.exit(2)
    if mbr[510] != 0x55 or mbr[511] != 0xAA:
        sys.stderr.write("FATAL: %s missing the 0x55 0xAA boot signature at 510/511\n"
                         % mbr_path)
        sys.exit(2)
    buf[0:SECTOR_BYTES] = mbr                          # LBA0 = the boot sector
    return bytes(buf)


def write_img(buf, path):
    with open(path, "wb") as f:
        f.write(buf)


def write_hex(buf, path):
    with open(path, "w") as f:
        f.write("".join("%02x\n" % b for b in buf))


def read_hex(path):
    out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            out.append(int(line, 16))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mbr", required=True, help="the 512-byte boot sector for LBA0")
    ap.add_argument("--img", required=True)
    ap.add_argument("--hex", required=True)
    ap.add_argument("--check", action="store_true",
                    help="drift assert: rebuild from the MBR and compare to the "
                         "on-disk .img and .hex; exit 1 on mismatch")
    args = ap.parse_args()

    buf = build_disk(args.mbr)

    if args.check:
        ok = True
        try:
            with open(args.img, "rb") as f:
                img = f.read()
            if img != buf:
                print("DRIFT: %s != generator buffer (%d vs %d bytes)"
                      % (args.img, len(img), len(buf)))
                ok = False
        except FileNotFoundError:
            print("DRIFT: %s missing" % args.img); ok = False
        try:
            hx = read_hex(args.hex)
            if hx != buf:
                print("DRIFT: %s != generator buffer (%d vs %d bytes)"
                      % (args.hex, len(hx), len(buf)))
                ok = False
        except FileNotFoundError:
            print("DRIFT: %s missing" % args.hex); ok = False
        if ok:
            print("disk drift check: pboot.img and pboot.disk.hex match the "
                  "generator buffer EXACTLY (%d bytes, boot sector at LBA0, single "
                  "source of truth)" % len(buf))
            return 0
        return 1

    write_img(buf, args.img)
    write_hex(buf, args.hex)
    print("wrote %s (%d bytes) + %s (%d lines): boot sector @LBA0 + %d zero sectors, "
          "geom 2/16/63" % (args.img, len(buf), args.hex, len(buf), DISK_SECTORS - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
