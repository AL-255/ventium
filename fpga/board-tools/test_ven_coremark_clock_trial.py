import struct
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ven_coremark_clock_trial as trial


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


if __name__ == '__main__': unittest.main()
