#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# task #99: convert a dumped mode-13h framebuffer (320x200x8, /tmp/sim_vga13.bin)
# + its DAC palette (/tmp/sim_vga13.pal, 256*3 6-bit RGB) into a PPM image so a
# soft-VGA-rendered DOS Quake frame can be viewed/checked offline.
#
# Usage: vga13_to_ppm.py [fb.bin] [pal.pal] [out.ppm]
import sys

fb_path  = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sim_vga13.bin"
pal_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/sim_vga13.pal"
out_path = sys.argv[3] if len(sys.argv) > 3 else "/tmp/sim_vga13.ppm"
W, H = 320, 200

fb = open(fb_path, "rb").read()
if len(fb) < W * H:
    fb = fb + b"\x00" * (W * H - len(fb))

# Palette: 256 entries of 6-bit R/G/B (VGA DAC). Scale <<2 to 8-bit. If missing,
# fall back to a grayscale ramp (index as intensity) so the frame is still visible.
try:
    pal = open(pal_path, "rb").read()
    if len(pal) < 768:
        pal = pal + b"\x00" * (768 - len(pal))
    rgb = [(min(pal[i*3+0] << 2, 255),
            min(pal[i*3+1] << 2, 255),
            min(pal[i*3+2] << 2, 255)) for i in range(256)]
except FileNotFoundError:
    rgb = [(i, i, i) for i in range(256)]

with open(out_path, "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (W, H))
    out = bytearray(W * H * 3)
    for i in range(W * H):
        r, g, b = rgb[fb[i]]
        out[i*3+0] = r; out[i*3+1] = g; out[i*3+2] = b
    f.write(out)

nz = sum(1 for i in range(W * H) if fb[i])
distinct = len(set(fb[:W*H]))
print("wrote %s  (%d nonzero px, %d distinct color indices)" % (out_path, nz, distinct))
