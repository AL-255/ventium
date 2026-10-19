import unittest
from ven_pll_clock import change, decode, HANDLE, COMMAND_LINES, STATUS_LINES


class Mailbox:
    def __init__(self):
        self.raw=0x504c5c99 # safe, locked, clock enabled, ACK1, divide25
        self.commands=[]
        self.claimed=False
        self.now=0
        self.fail=False
        self.stall=False
        self.accepted=[]
    def read(self): return self.raw
    def claim_output(self): self.claimed=True; self.write(0)
    def write(self,value):
        self.commands.append(value)
        if (value >> 7) & 255 == 0xc1 and value >> 15 != (self.raw >> 11)&1:
            self.accepted.append(value)
            if self.stall: return
            self.raw = 0x504c5400 | (value >> 15) << 11 | (value & 127) | 128
            if self.fail: self.raw |= 512
    def sleep(self,n): self.now+=n
    def run(self,div=14): return change(self,div,monotonic=lambda:self.now,sleep=self.sleep)


class Pll(unittest.TestCase):
    def test_gpio_layout(self):
        self.assertEqual(HANDLE.size,364)
        self.assertEqual(COMMAND_LINES,tuple(range(110,126)))
        self.assertEqual(STATUS_LINES,tuple(range(142,173)))
        self.assertFalse(set(COMMAND_LINES)&set(STATUS_LINES))
    def test_abi(self):
        for raw in (0,0xffffffff,0x504c0000,0x504c8000):
            with self.subTest(raw=raw),self.assertRaises(ValueError): decode(raw)
    def test_stages_before_toggle_for_either_ack(self):
        for ack in (0,1):
            b=Mailbox(); b.raw=(b.raw & ~2048)|(ack<<11)
            result=b.run()
            self.assertEqual(len(b.accepted),1)
            self.assertEqual(b.commands,[0,ack<<15,(ack<<15)|(0xc1<<7)|14,((1-ack)<<15)|(0xc1<<7)|14])
            self.assertAlmostEqual(result['expected_mhz'],71.4285714286)
            self.assertFalse(result['reprogrammed'])
            self.assertFalse(result['acceptance'])
    def test_bounds_checked_before_any_mutation(self):
        for div in (0,9,51,25.0,True):
            b=Mailbox()
            with self.subTest(div=div),self.assertRaises(ValueError): b.run(div)
            self.assertFalse(b.claimed)
    def test_unsafe_or_busy_rejected_before_output_claim(self):
        for raw in (0x504c4c99,0x504c5d99):
            b=Mailbox(); b.raw=raw
            with self.assertRaises(ValueError): b.run()
            self.assertFalse(b.claimed)
    def test_error_and_timeout_not_passes(self):
        b=Mailbox(); b.fail=True
        with self.assertRaises(RuntimeError): b.run()
        b=Mailbox(); b.stall=True
        with self.assertRaises(TimeoutError): b.run()
    def test_can_recover_a_fail_closed_controller(self):
        b=Mailbox(); b.raw=0x504c7a99 & ~128
        self.assertTrue(decode(b.raw)['error'])
        self.assertEqual(b.run(25)['after']['divider'],25)


if __name__ == '__main__': unittest.main()
