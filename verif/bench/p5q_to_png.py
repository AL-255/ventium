#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Convert a captured P5Q1 video stream (Quake's vid_p5fb.c frame protocol) into
PNG frames. Stream layout (little-endian):
    once:      int32 magic 'P5Q1'(0x31513550), int32 width, int32 height
    per frame: byte palette[768] (256*RGB), byte pixels[width*height] (8-bit idx)
8-bit paletted -> RGB via the per-frame palette. Stdlib only (zlib for PNG).

    p5q_to_png.py <stream.p5q> <out_dir> [--every N] [--max M]
Writes <out_dir>/frameNNNN.png; prints the frame count.
"""
import struct, sys, zlib, os

def png(path, w, h, rgb):
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = bytearray()
    for y in range(h):
        raw.append(0)                      # filter: none
        raw += rgb[y*w*3:(y+1)*w*3]
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))  # 8-bit RGB
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)

def main():
    if len(sys.argv) < 3:
        print("usage: p5q_to_png.py <stream.p5q> <out_dir> [--every N] [--max M]"); return 2
    path, outd = sys.argv[1], sys.argv[2]
    every = int(sys.argv[sys.argv.index("--every")+1]) if "--every" in sys.argv else 1
    mx    = int(sys.argv[sys.argv.index("--max")+1])   if "--max"   in sys.argv else 1_000_000
    data = open(path, "rb").read()
    if len(data) < 12 or struct.unpack("<I", data[:4])[0] != 0x31513550:
        print(f"not a P5Q1 stream ({len(data)} bytes)"); return 1
    w, h = struct.unpack("<II", data[4:12])
    os.makedirs(outd, exist_ok=True)
    pos = 12; frame = 0; written = 0
    fsz = 768 + w*h
    while pos + fsz <= len(data) and written < mx:
        pal = data[pos:pos+768]; px = data[pos+768:pos+fsz]; pos += fsz
        if frame % every == 0:
            rgb = bytearray(w*h*3)
            for i, p in enumerate(px):
                rgb[i*3:i*3+3] = pal[p*3:p*3+3]
            png(os.path.join(outd, f"frame{written:04d}.png"), w, h, bytes(rgb))
            written += 1
        frame += 1
    print(f"P5Q1 {w}x{h}: {frame} frames in stream, wrote {written} PNG(s) to {outd}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
