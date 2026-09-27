#!/usr/bin/env python3
"""Render a static, unpanned byte-addressed 256-color VGA memory view.

Consumes read_native_vga.py output, never a running simulator or writable guest.
This is a decoded VRAM diagnostic, NOT sampled VGA-pin/video timing validation.
Unsupported CRTC modes fail closed. Colors are the stored six-bit DAC values,
linearly expanded to eight bits; no gamma, contrast or brightness processing.
"""
import argparse
import json
from pathlib import Path
import struct

from read_native_vga import digest, need


def render(registers, planes, dac):
    expected = dict(graph_shift_mode=2, attrib_pelclock_div2=1,
                    attrib_graphic_mode=1, attrib_mask=15, attrib_blinking=0,
                    attrib_color_bit5_4_enable=0, attrib_color_bit7_6_value=0,
                    crtc_address_doubleword=0, crtc_address_byte=1,
                    crtc_address_bit13=1, crtc_address_bit14=1,
                    crtc_vertical_doublescan=0, crtc_row_preset=0, crtc_row_max=0,
                    seq_8dot_char=1, seq_dotclock_divided=0,
                    seq_screen_disable=0, crtc_timing_enable=1,
                    memory_panning_reg=0, crtc_address_byte_panning=0)
    for key, value in expected.items():
        need(registers.get(key) == value, 'unsupported register: '+key)
    width = (registers['crtc_horizontal_display_size'] + 1) * 4
    height = registers['crtc_vertical_display_size'] + 1
    need(0 < width <= 2048 and 0 < height <= 2048, 'invalid dimensions')
    need(registers['crtc_line_compare'] >= height, 'split screen unsupported')
    need(len(planes) == 4 and all(len(p) == 65536 for p in planes), 'bad plane extent')
    need(len(dac) == 1024, 'bad DAC extent')
    colors = struct.unpack('<256I', dac)
    need(all(c < (1 << 18) for c in colors), 'invalid DAC entry')
    palette = [bytes(((c >> 12) * 255 // 63, ((c >> 6) & 63) * 255 // 63,
                      (c & 63) * 255 // 63)) for c in colors]
    start = registers['memory_address_start_reg']
    stride = registers['crtc_address_offset'] * 2
    mask = registers['dac_mask']
    need(0 <= start < 65536 and 0 < stride < 1024 and 0 <= mask <= 255,
         'invalid address/mask')
    # vga.v memory_address advances once per four 256-color pixels. In byte
    # addressing mode memory_address_step_1/2 are identity. Its shift-register
    # shuffle emits the four plane bytes in order, using direct DAC indices.
    rgb = bytearray()
    for y in range(height):
        for x in range(width):
            addr = (start + y * stride + (x >> 2)) & 0xffff
            rgb.extend(palette[planes[x & 3][addr] & mask])
    return f'P6\n{width} {height}\n255\n'.encode() + rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True, help='fresh PPM path')
    args = parser.parse_args()
    need(not args.out.exists() and not args.out.is_symlink(), 'output exists')
    files = [args.input / 'vga.json'] + [args.input / (n+'__DOT__mem.bin') for n in
                                       ['plane_ram_0', 'plane_ram_1', 'plane_ram_2', 'plane_ram_3', 'dac_ram']]
    before = {str(p): digest(p) for p in files}
    metadata = json.loads(files[0].read_text())
    picture = render(metadata['registers'], [p.read_bytes() for p in files[1:5]], files[5].read_bytes())
    need(all(digest(p) == h for p, h in before.items()), 'input drift')
    receipt_path = args.out.with_suffix('.json')
    need(receipt_path != args.out and not receipt_path.exists() and not receipt_path.is_symlink(),
         'receipt exists or aliases output')
    with args.out.open('xb') as stream:
        stream.write(picture)
    with receipt_path.open('x') as stream:
        json.dump(dict(scope=__doc__, input_sha256=before, output_sha256=digest(args.out),
                       driver_sha256=digest(__file__), snapshot=metadata['snapshot']), stream, indent=2)
        stream.write('\n')
    print('VGA256-VRAM-VIEW-OK', args.out)


if __name__ == '__main__':
    main()
