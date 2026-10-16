import struct
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ven_coremark_clock_trial as trial
from test_ven_pll_clock import Mailbox


class Api:
    R_DBG_ARCH_SEL = 0x2a0
    R_DBG_ARCH_DATA = 0x2b0
    def require_exec_debug(self, ctrl): pass
    def u32(self, ctrl, off): return struct.unpack_from('<I',ctrl,off)[0]


class Quiesce(unittest.TestCase):
    def board(self, status=0x50440003):
        ctrl = bytearray(4096)
        struct.pack_into('<I', ctrl, 0x2a0, 17)
        struct.pack_into('<I', ctrl, 0x2b0, status)
        return ctrl

    def test_requires_two_clean_observations_and_restores_selector(self):
        ctrl = self.board()
        result = trial.quiesce(ctrl, api=Api(), sleep=lambda _:None)
        self.assertEqual(result['polls'], 2)
        self.assertEqual(Api().u32(ctrl, 0x20), 1)
        self.assertEqual(Api().u32(ctrl, 0x2a0), 17)

    def test_unsupported_fault_and_timeout_rejected(self):
        for status, error in ((0,ValueError), (0x50440007,ValueError),
                              (0x50440001,ValueError), (0x50440002,TimeoutError)):
            ctrl = self.board(status)
            with self.subTest(status=status), self.assertRaises(error):
                trial.quiesce(ctrl, api=Api(), sleep=lambda _:None)
            self.assertEqual(Api().u32(ctrl, 0x2a0), 17)

    def test_competing_selector_not_overwritten(self):
        ctrl = self.board()
        def changed(_): struct.pack_into('<I', ctrl, 0x2a0, 3)
        with self.assertRaises(ValueError): trial.quiesce(ctrl, api=Api(), sleep=changed)
        self.assertEqual(Api().u32(ctrl, 0x2a0), 3)

    def test_healthy_clock_cleanup_is_read_only(self):
        b=Mailbox()
        result=trial.cleanup_clock(b,sleep=b.sleep)
        self.assertTrue(result['clock_usable'])
        self.assertFalse(result['recovered'])
        self.assertFalse(b.claimed)

    def test_stopped_safe_clock_can_recover_but_not_accept_trial(self):
        b=Mailbox(); b.raw=0x504c7a19
        result=trial.cleanup_clock(b,sleep=b.sleep)
        self.assertTrue(result['clock_usable'])
        self.assertTrue(result['recovered'])
        self.assertEqual(result['after']['divider'],25)
        self.assertFalse(result['recovery']['acceptance'])

    def test_unsafe_stopped_clock_does_not_touch_command_or_mmio(self):
        b=Mailbox(); b.raw=0x504c6a19
        result=trial.cleanup_clock(b,sleep=b.sleep)
        self.assertFalse(result['clock_usable'])
        self.assertFalse(b.claimed)

    def test_failed_recovery_is_not_a_usable_clock(self):
        b=Mailbox(); b.raw=0x504c7a19; b.fail=True
        result=trial.cleanup_clock(b,sleep=b.sleep)
        self.assertFalse(result['clock_usable'])
        self.assertIn('error',result)

    def test_clock_is_checked_before_management_can_be_mapped(self):
        for raw in (0x504c7a19,0x504c5d99,0x504c5899,0x504c5e99):
            b=Mailbox(); b.raw=raw
            with self.subTest(raw=raw),self.assertRaises(RuntimeError):
                trial.require_running_clock(b)
            self.assertFalse(b.claimed)
        self.assertTrue(trial.require_running_clock(Mailbox())['clock_enabled'])


if __name__ == '__main__': unittest.main()
