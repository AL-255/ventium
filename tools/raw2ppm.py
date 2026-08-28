#!/usr/bin/env python3
"""raw2ppm.py — convert fgrab raw mode-13h index frames to PPMs with the Quake palette.

Usage: raw2ppm.py <palette.bin> <outdir> <frame1.raw> [frame2.raw ...]
Each 64000-byte raw frame (320x200 palette indices) becomes <outdir>/<name>.ppm.
"""
import sys, os

def main():
    pal = open(sys.argv[1], 'rb').read()
    assert len(pal) == 768
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    for path in sys.argv[3:]:
        raw = open(path, 'rb').read()
        if len(raw) != 64000:
            print(f"skip {path}: {len(raw)} bytes != 64000"); continue
        rgb = bytearray(64000 * 3)
        for i, idx in enumerate(raw):
            rgb[i*3]   = pal[idx*3]
            rgb[i*3+1] = pal[idx*3+1]
            rgb[i*3+2] = pal[idx*3+2]
        name = os.path.splitext(os.path.basename(path))[0] + '.ppm'
        with open(os.path.join(outdir, name), 'wb') as f:
            f.write(b'P6\n320 200\n255\n'); f.write(rgb)

if __name__ == '__main__':
    main()
