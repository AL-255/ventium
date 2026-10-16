import unittest

import ven_board_probe as probe
from ven_cold_clock import measure


class FakeBoard:
    R_IDENT = probe.R_IDENT
    IDENT_MAGIC = probe.IDENT_MAGIC
    R_DBG_FRZINFO = probe.R_DBG_FRZINFO
    R_DBG_CR0 = probe.R_DBG_CR0
    R_DBG_CYC_LO = probe.R_DBG_CYC_LO
    R_DBG_CYC_HI = probe.R_DBG_CYC_HI
    R_DBG_RET_LO = probe.R_DBG_RET_LO
    R_DBG_RET_HI = probe.R_DBG_RET_HI

    def __init__(self, mhz=40, event=None):
        self.ns = 0
        self.cycles = 0
        self.mhz = mhz
        self.abi = 0x56450005
        self.ident = self.IDENT_MAGIC
        self.reset = 1
        self.frozen = 0
        self.cr0 = 0x60000010
        self.retired = 0
        self.event = event
        self.read_delay_ns = 0

    def require_exec_debug(self, ctrl):
        if self.abi != 0x56450005:
            raise ValueError('unsupported ABI')

    def u32(self, ctrl, offset):
        return {self.R_IDENT:self.ident, 0x20:self.reset,
                self.R_DBG_FRZINFO:self.frozen, self.R_DBG_CR0:self.cr0}[offset]

    def stable_u64(self, ctrl, lo, hi):
        if (lo, hi) == (self.R_DBG_CYC_LO, self.R_DBG_CYC_HI):
            result = self.cycles
            self.ns += self.read_delay_ns
            return result
        assert (lo, hi) == (self.R_DBG_RET_LO, self.R_DBG_RET_HI)
        return self.retired

    def sleep(self, seconds):
        self.ns += round(seconds*1e9)
        self.cycles += round(seconds*self.mhz*1e6)
        if self.event and self.ns >= 1_000_000_000:
            self.event(self)
            self.event = None

    def measure(self):
        return measure(None, api=self, monotonic_ns=lambda:self.ns, sleep=self.sleep)


class ColdClockTests(unittest.TestCase):
    def test_40mhz_held_is_not_cpu_or_uv_acceptance(self):
        result = FakeBoard().measure()
        self.assertEqual(result['measured_core_mhz'], 40)
        self.assertGreaterEqual(result['guard_checks'], 100)
        for flag in ('uv_fast_qualified', 'sta_signoff', 'acceptance'):
            self.assertFalse(result[flag])
        self.assertIsNone(result['gameplay_ipc'])
        self.assertTrue(result['read_only'])

    def test_wrong_clock_and_stopped_clock_rejected(self):
        for mhz in (0, 3.125, 20, 37.5, 45, 70):
            with self.subTest(mhz=mhz), self.assertRaises(ValueError):
                FakeBoard(mhz).measure()

    def test_unknown_abi_rejected_without_waiting(self):
        board = FakeBoard()
        board.abi = 0x56450009
        with self.assertRaises(ValueError): board.measure()
        self.assertEqual(board.ns, 0)

    def test_initial_state_rejected_without_waiting(self):
        for name, value in [('ident',0), ('reset',0), ('frozen',0x80000000),
                            ('cr0',0x80000011), ('retired',1)]:
            board = FakeBoard(); setattr(board,name,value)
            with self.subTest(name=name), self.assertRaises(ValueError): board.measure()
            self.assertEqual(board.ns, 0)

    def test_mid_interval_state_changes_rejected(self):
        for name, value in [('abi',0x56450009), ('reset',0), ('frozen',0x80000000),
                            ('cr0',0x80000011), ('retired',1)]:
            board = FakeBoard(event=lambda b,n=name,v=value:setattr(b,n,v))
            with self.subTest(name=name), self.assertRaises(ValueError): board.measure()

    def test_counter_reset_is_not_wrap(self):
        board = FakeBoard(event=lambda b:setattr(b,'cycles',0))
        with self.assertRaisesRegex(ValueError, 'reset/clear'): board.measure()

    def test_uncertain_read_rejected(self):
        board = FakeBoard(); board.read_delay_ns=200_000_000
        with self.assertRaises(ValueError): board.measure()

    def test_explicit_experimental_frequency(self):
        board = FakeBoard(70)
        result = measure(None, expected_mhz=70, api=board,
                         monotonic_ns=lambda:board.ns, sleep=board.sleep)
        self.assertEqual(result['measured_core_mhz'], 70)
        self.assertEqual(result['result'], 'PASS_HELD_RESET_EXPERIMENTAL_CLOCK_ONLY')
        self.assertFalse(result['acceptance'])
        board = FakeBoard(40)
        with self.assertRaises(ValueError):
            measure(None, expected_mhz=70, api=board,
                    monotonic_ns=lambda:board.ns, sleep=board.sleep)

    def test_invalid_experimental_target_rejected(self):
        for target in (0, 19, 101, float('nan'), float('inf')):
            board = FakeBoard()
            with self.subTest(target=target), self.assertRaises(ValueError):
                measure(None, expected_mhz=target, api=board,
                        monotonic_ns=lambda:board.ns, sleep=board.sleep)
            self.assertEqual(board.ns, 0)


if __name__ == '__main__':
    unittest.main()
