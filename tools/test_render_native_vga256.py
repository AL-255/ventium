import struct
import unittest
from render_native_vga256 import render


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.reg = dict(graph_shift_mode=2, attrib_pelclock_div2=1,
                        attrib_graphic_mode=1, attrib_mask=15, attrib_blinking=0,
                        attrib_color_bit5_4_enable=0, attrib_color_bit7_6_value=0,
                        crtc_address_doubleword=0, crtc_address_byte=1,
                        crtc_address_bit13=1, crtc_address_bit14=1,
                        crtc_vertical_doublescan=0, crtc_row_preset=0, crtc_row_max=0,
                        seq_8dot_char=1, seq_dotclock_divided=0, seq_screen_disable=0,
                        crtc_timing_enable=1, memory_panning_reg=0, crtc_address_byte_panning=0,
                        crtc_horizontal_display_size=1, crtc_vertical_display_size=1,
                        crtc_line_compare=1023, crtc_address_offset=2,
                        memory_address_start_reg=65535, dac_mask=255)
        self.planes = [bytearray(65536) for _ in range(4)]
        self.colors = [0] * 256
        self.colors[1:5] = [63 << 12, 63 << 6, 63, (1 << 18)-1]
        for i, plane in enumerate(self.planes):
            plane[65535] = i+1
            plane[0] = 4-i
            plane[3] = 4
            plane[4] = 1

    def image(self):
        return render(self.reg, self.planes, struct.pack('<256I', *self.colors))

    def test_plane_order_wrap_stride_and_raw_colors(self):
        red, green, blue, white = bytes((255,0,0)), bytes((0,255,0)), bytes((0,0,255)), bytes((255,255,255))
        self.assertEqual(self.image(), b'P6\n8 2\n255\n' + red+green+blue+white +
                         white+blue+green+red + white*4+red*4)

    def test_mask_is_applied(self):
        self.reg['dac_mask'] = 0
        self.assertEqual(self.image(), b'P6\n8 2\n255\n' + bytes(48))

    def test_reject_unsupported_modes(self):
        for key in ('graph_shift_mode', 'attrib_mask', 'crtc_address_byte',
                    'crtc_row_max', 'memory_panning_reg', 'crtc_address_doubleword'):
            old = self.reg[key]
            self.reg[key] ^= 1
            try:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    self.image()
            finally:
                self.reg[key] = old
        self.colors[0] = 1 << 18
        with self.assertRaises(ValueError):
            self.image()


if __name__ == '__main__':
    unittest.main()
