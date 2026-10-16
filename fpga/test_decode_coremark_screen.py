import unittest
import zlib
from pathlib import Path
import decode_coremark_screen as screen


class Screens(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.glyphs = screen.font((screen.REPO/'3rd-party/ao486_MiSTer/releases/boot1.rom').read_bytes())

    def raster(self, width):
        pixels = bytearray(width*400)
        for col, char in enumerate('CoreMark CRC 0x4983'):
            for y, bits in enumerate(self.glyphs[ord(char)*16:(ord(char)+1)*16]):
                for x in range(8):
                    pixels[y*width+col*(width//80)+x] = 0x6d if bits & (128 >> x) else 0
        return pixels

    def test_both_cell_widths(self):
        for width in (640, 720):
            result = screen.decode(self.raster(width), width, 400, self.glyphs)
            self.assertTrue(result['exact_glyphs'])
            self.assertEqual(result['text'].splitlines()[0], 'CoreMark CRC 0x4983')
            self.assertFalse(result['physical_board_qualified'])

    def test_no_fuzzy_repair(self):
        pixels = self.raster(720)
        pixels[0] = 0x6d
        self.assertFalse(screen.decode(pixels, 720, 400, self.glyphs)['exact_glyphs'])
        pixels = self.raster(720)
        pixels[8] = 0x6d
        self.assertFalse(screen.decode(pixels, 720, 400, self.glyphs)['exact_glyphs'])

    def test_capture_integrity(self):
        pixels = self.raster(720)
        data = (screen.STREAM.pack(b'VENVCAP1',1,1) +
                screen.FRAME.pack(b'VFRM',3,4,5,720,400,len(pixels),zlib.crc32(pixels)) + pixels)
        self.assertEqual(screen.frame(data)[0], pixels)
        for broken in (data[:-1], data+b'x', data[:-1]+b'x', data[:20]):
            with self.assertRaises(ValueError): screen.frame(broken)

    def test_wrong_rom_rejected(self):
        with self.assertRaises(ValueError): screen.font(bytes(32768))

    def test_nine_dot_replacement_is_from_rom(self):
        rom = (screen.REPO/'3rd-party/ao486_MiSTer/releases/boot1.rom').read_bytes()
        self.assertEqual(screen.font(rom, 9)[77*16:78*16].hex(),
                         '0000c3e7ffffdbc3c3c3c3c300000000')
        self.assertNotEqual(screen.font(rom, 8), screen.font(rom, 9))


if __name__ == '__main__': unittest.main()
