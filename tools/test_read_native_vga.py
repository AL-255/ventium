"""Small host-only layout tests; never load or modify a guest snapshot."""
import mmap
import struct
import tempfile
import unittest

from read_native_vga import datatype, declarations, serializer_layout, snapshot_payload


def serializer(body):
    return ('void Vsystem___024root::__Vserialize(VerilatedSerialize& os) {\n'
            'uint64_t __Vcheckval = 0x1234ULL;\nos << __Vcheckval;\n'
            'os << vlSymsp->_vm_contextp__;\n' + body + '\n}\n'
            'void Vsystem___024root::__Vdeserialize')


class LayoutTests(unittest.TestCase):
    def test_types_and_declarations(self):
        self.assertEqual(datatype('VlUnpacked<VlWide<3>, 4>'), (4, [4, 3]))
        self.assertEqual(datatype('CData/*7:0*/'), (1, []))
        header = ('// DESIGN SPECIFIC STATE\nstruct {\nVL_IN8(clk,0,0);\n'
                  'VL_OUTW(bus,95,0,3);\nVlUnpacked<CData/*7:0*/, 16> ram;\n'
                  '};\n// INTERNAL VARIABLES')
        self.assertEqual(declarations(header),
                         dict(clk=(1, []), bus=(4, [3]), ram=(1, [16])))
        for bad in ('VlWide<0>', 'VlUnpacked<CData, 0>', 'std::string', 'signed int'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                datatype(bad)

    def test_layout_and_reject_noncontiguous_fields(self):
        loop = 'for (int __Vi0 = 0; __Vi0 < 2; ++__Vi0) {\nos << ram[__Vi0];\n}'
        fields = dict(flag=(1, []), ram=(4, [2]), other=(1, [2]))
        check, layout, size = serializer_layout(serializer('os << flag;\n'+loop), fields)
        self.assertEqual((check, size), (0x1234, 9))
        self.assertEqual(layout['ram']['offset'], 1)
        bads = [loop.replace('< 2', '< 3'), loop.replace('__Vi0];', '__Vi1];'),
                loop.replace('os << ram[__Vi0];', ''),
                loop.replace('os << ram[__Vi0];',
                             'os << ram[__Vi0];\nos << other[__Vi0];'),
                'os << flag;\nos << flag;', 'os.write(&flag, 1);', '}']
        for bad in bads:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                serializer_layout(serializer(bad), fields)

    def test_snapshot_boundaries_and_corruption(self):
        # Sparse backing keeps this faithful to the fixed 128-MiB harness ABI
        # without allocating/initializing a 128-MiB Python object.
        config = (45000000, 45000000, 90000000, 32, 2, 2, 4, 1, 32)
        prefix = (b'verilatorsave02\n' + struct.pack('<Q9I3II',
                  0x3350414e534e4556, *config, 0, 3, 61446, 1) + bytes(32) +
                  struct.pack('<QQ', 200000000, 31255534))
        context = b'context-' * 7
        payload = b'ABCxyz'
        # One outstanding read with three u64 fields exercises FIFO sizing.
        tail = (struct.pack('<Q3QBIIiIBQ', 1, 10, 20, 30, 0, 5, 0, 1, 7, 1, 0x1234) +
                context + payload + struct.pack('<Q', 0x5678) + context + b'vltsaved')
        tail_offset = len(prefix) + (1 << 27)
        with tempfile.TemporaryFile() as stream:
            stream.write(prefix)
            stream.seek(tail_offset)
            stream.write(tail)
            stream.flush()
            with mmap.mmap(stream.fileno(), 0) as data:
                start, meta = snapshot_payload(data, 0x1234, len(payload), 0x5678)
                self.assertEqual(data[start:start+len(payload)], payload)
                self.assertEqual(meta['cycle'], 200000000)
                self.assertEqual(meta['retires'], 31255534)
                self.assertEqual(meta['context_bytes'], 56)
                corrupt = [0, 16, 24, 72, tail_offset+7, start-1,
                           start+len(payload), len(data)-1]
                for offset in corrupt:
                    old = data[offset]
                    data[offset] ^= 0x80
                    try:
                        with self.subTest(offset=offset), self.assertRaises(ValueError):
                            snapshot_payload(data, 0x1234, len(payload), 0x5678)
                    finally:
                        data[offset] = old
                with self.assertRaises(ValueError):
                    snapshot_payload(data, 0x1235, len(payload), 0x5678)
                with self.assertRaises(ValueError):
                    snapshot_payload(data, 0x1234, len(payload)+1, 0x5678)


if __name__ == '__main__':
    unittest.main()
