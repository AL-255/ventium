"""Read-only hidden-CS observation, including malformed/unsupported replies."""
import unittest
from gen_trace import RSPClient, RSPError


class FakeRSP:
    read_system_cs_base = RSPClient.read_system_cs_base

    def __init__(self, packets):
        self.packets = iter(packets)
        self.sent = []

    def send(self, packet):
        self.sent.append(packet)

    def recv(self):
        return next(self.packets)


def output(data):
    return b'O'+data.hex().encode()


class HiddenCS(unittest.TestCase):
    def test_real_reset_protected_and_unreal(self):
        for selector,base in ((0xf000,0xffff0000),(0xf000,0xf0000),(0x28,0x9000),
                              (8,0),(0x900,0x12340000)):
            with self.subTest(selector=selector,base=base):
                line=f'\nCS ={selector:04x} {base:08x} 0000ffff 00009b00\n'.encode()
                rsp=FakeRSP([output(line[:13]),output(line[13:]),b'OK'])
                self.assertEqual(rsp.read_system_cs_base(selector),base)
                self.assertEqual(rsp.sent,['qRcmd,'+b'info registers'.hex()])

    def test_reload_same_selector_is_not_cached(self):
        rsp=FakeRSP([output(b'CS =0028 00009000 0000ffff\n'),b'OK',
                     output(b'CS =0028 0000a000 0000ffff\n'),b'OK'])
        self.assertEqual(rsp.read_system_cs_base(0x28),0x9000)
        self.assertEqual(rsp.read_system_cs_base(0x28),0xa000)
        self.assertEqual(len(rsp.sent),2)

    def test_unsupported_or_error_reply(self):
        for packet in (b'',b'E22',b'T05',b'unknown'):
            with self.subTest(packet=packet),self.assertRaises(RSPError):
                FakeRSP([packet]).read_system_cs_base(8)

    def test_malformed_hex(self):
        for packet in (b'Ozz',b'O0',b'O\xff'):
            with self.subTest(packet=packet),self.assertRaises(RSPError):
                FakeRSP([packet]).read_system_cs_base(8)

    def test_missing_duplicate_selector_mismatch_or_large_base(self):
        for body in (b'', b'CS =0008 00000000 0000ffff\n'*2,
                     b'CS =0010 00000000 0000ffff\n',b'CS =0008 0000000100000000 0000ffff\n'):
            with self.subTest(body=body),self.assertRaises(RSPError):
                FakeRSP([output(body),b'OK']).read_system_cs_base(8)

    def test_bounded_output(self):
        with self.assertRaises(RSPError):
            FakeRSP([output(b'x'*65537)]).read_system_cs_base(8)


if __name__=='__main__': unittest.main()
