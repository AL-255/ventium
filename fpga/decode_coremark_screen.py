"""Exact ROM-glyph decoding of one passive VGA capture, not heuristic OCR.

The board's DDR B8000 aperture is not its live VGA RAM. Read the existing
scanout recorder instead. Preserve the capture and reject unknown glyphs before
grading a benchmark. This module never accesses a board or changes guest state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

REPO = Path(__file__).resolve().parents[1]
ROM_SHA = 'fb0d673a4cc3a96c388b4404db262db70bdde0746ee1ef9284923a5661e08296'
FONT_OFFSET = 17671
STREAM = struct.Struct('<8sII')
FRAME = struct.Struct('<4sIQQHHII')


def font(rom, cell_width=9):
    if hashlib.sha256(rom).hexdigest() != ROM_SHA:
        raise ValueError('font address requires the exact deployed VGA ROM')
    # The release ROM contains a primary font plus indexed 9-dot replacement
    # glyphs. Decode those actual bytes, not the checkout's different C table.
    glyphs = bytearray(rom[FONT_OFFSET:FONT_OFFSET + 256*16])
    if cell_width not in (8, 9):
        raise ValueError('unsupported text cell width')
    if cell_width == 9:
        offset = FONT_OFFSET + 256*16
        seen = set()
        while rom[offset]:
            char = rom[offset]
            if char in seen or offset+17 > len(rom):
                raise ValueError('malformed alternate font')
            seen.add(char)
            glyphs[char*16:(char+1)*16] = rom[offset+1:offset+17]
            offset += 17
    return bytes(glyphs)


def frame(data):
    if len(data) < STREAM.size + FRAME.size:
        raise ValueError('truncated capture')
    if STREAM.unpack_from(data) != (b'VENVCAP1', 1, 1):
        raise ValueError('require one complete VENVCAP1 frame')
    marker, sequence, host_ns, cycle, width, height, pixels, checksum = FRAME.unpack_from(data, STREAM.size)
    payload = data[STREAM.size + FRAME.size:]
    if (marker != b'VFRM' or pixels != width*height or len(payload) != pixels or
            zlib.crc32(payload) & 0xffffffff != checksum):
        raise ValueError('capture marker, extent or CRC mismatch')
    return payload, dict(sequence=sequence, host_monotonic_ns=host_ns,
                         fpga_cycle=cycle, width=width, height=height, crc32=f'{checksum:08x}')


def decode(pixels, width, height, glyphs):
    if width not in (640, 720) or height != 400 or len(pixels) != width*height:
        raise ValueError('requires 80x25, 8/9x16 text scanout')
    if len(glyphs) != 4096:
        raise ValueError('invalid font extent')
    lookup = {}
    for char in range(32, 127):
        key = glyphs[char*16:(char+1)*16]
        if key in lookup:
            raise ValueError('ambiguous printable ROM glyphs')
        lookup[key] = chr(char)
    cell_width = width//80
    lines, unknown = [], []
    for row in range(25):
        line = ''
        for col in range(80):
            bitmap = bytearray()
            ninth_clear = True
            for y in range(16):
                start = (row*16+y)*width + col*cell_width
                bitmap.append(sum((pixels[start+x] != 0) << (7-x) for x in range(8)))
                if cell_width == 9 and pixels[start+8] != 0:
                    ninth_clear = False
            char = lookup.get(bytes(bitmap)) if ninth_clear else None
            if char is None:
                unknown.append(dict(row=row, col=col, bitmap=bitmap.hex(), ninth_clear=ninth_clear))
                char = '\ufffd'
            line += char
        lines.append(line.rstrip())
    return dict(text='\n'.join(lines)+'\n', unknown=unknown,
                exact_glyphs=not unknown, physical_board_qualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--rom', type=Path, default=REPO/'3rd-party/ao486_MiSTer/releases/boot1.rom')
    args = parser.parse_args()
    pixels, metadata = frame(args.capture.read_bytes())
    result = decode(pixels, metadata['width'], metadata['height'],
                    font(args.rom.read_bytes(), metadata['width']//80))
    print(result['text'], end='')
    print(json.dumps(dict(metadata=metadata, unknown=result['unknown'],
                          exact_glyphs=result['exact_glyphs'])), file=sys.stderr)
    return 0 if result['exact_glyphs'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
