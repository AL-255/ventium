#!/usr/bin/env python3
"""Ventium M8.4 IDE — single-source-of-truth disk image generator.

Emits BOTH artifacts from ONE in-memory byte buffer, so the qemu-system backing
image and the RTL backing store CANNOT drift:

  * pide.img       -> qemu-system via `-drive if=ide,format=raw,index=0,file=...`
  * pide.disk.hex  -> ven_ide via `$readmemh` (one byte per line, hex, ASCENDING
                      disk offset: sector 0 byte 0 first)

Disk geometry (M8.4a): 128 sectors * 512 B = 64 KiB. qemu's guess_chs_for_size
for 128 sectors gives cyls=2, heads=16, secs=63 (clamp(128/(16*63),2,16383)=2).
ven_ide is parameterized with the SAME DISK_SECTORS/CYLS/HEADS/SECS, so the
IDENTIFY geometry words and the image size can never disagree.

Content (deterministic, distinctive per-LBA so an LBA->offset addressing bug
shows immediately):
  byte at offset (LBA*512 + k):
    low  byte of word j (k=2j)   = j & 0xFF        (word index within sector)
    high byte of word j (k=2j+1) = LBA & 0xFF      (which sector)
  => word j of sector L (little-endian as the CPU reads it) = (L<<8) | j
  EXCEPT sector 0 bytes 510/511 = 0x55,0xAA (a boot-signature marker; so the
  last word of sector 0 reads 0xAA55).

Usage:
  gen_disk.py --img pide.img --hex pide.disk.hex     # generate both
  gen_disk.py --check --img pide.img --hex pide.disk.hex   # drift assert only
"""
import argparse
import sys

DISK_SECTORS = 128
SECTOR_BYTES = 512


def build_disk():
    buf = bytearray(DISK_SECTORS * SECTOR_BYTES)
    for lba in range(DISK_SECTORS):
        base = lba * SECTOR_BYTES
        for j in range(SECTOR_BYTES // 2):          # 256 words/sector
            buf[base + 2 * j] = j & 0xFF            # low byte = word index
            buf[base + 2 * j + 1] = lba & 0xFF      # high byte = sector LBA
    # boot-signature marker at the end of sector 0 (last word reads 0xAA55)
    buf[510] = 0x55
    buf[511] = 0xAA
    return bytes(buf)


def write_img(buf, path):
    with open(path, "wb") as f:
        f.write(buf)


def write_hex(buf, path):
    # $readmemh: one 2-digit hex byte per line, ascending address (disk[0] first).
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
    ap.add_argument("--img", required=True)
    ap.add_argument("--hex", required=True)
    ap.add_argument("--check", action="store_true",
                    help="drift assert: rebuild from the buffer and compare to "
                         "the on-disk .img and .hex; exit 1 on mismatch")
    args = ap.parse_args()

    buf = build_disk()

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
            print("disk drift check: pide.img and pide.disk.hex match the "
                  "generator buffer EXACTLY (%d bytes, single source of truth)"
                  % len(buf))
            return 0
        return 1

    write_img(buf, args.img)
    write_hex(buf, args.hex)
    print("wrote %s (%d bytes) + %s (%d lines): %d sectors, geom 2/16/63"
          % (args.img, len(buf), args.hex, len(buf), DISK_SECTORS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
