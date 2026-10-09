from pathlib import Path
import unittest
from prepare_l2_init_backpressure import transform


class InitReady(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=(Path(__file__).resolve().parents[2]/'3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v').read_text()

    def test_both_legacy_and_streaming_assignments(self):
        fixed=transform(self.source)
        self.assertEqual(fixed.count('assign CPU_BUSY       = (RESET || RESET_1 || (state == START)) ? 1\'b1 :'),2)
        self.assertEqual(fixed.count('(state == IDLE) ? DDRAM_BUSY :'),2)
        self.assertEqual(fixed.count('always @(posedge CLK)'),self.source.count('always @(posedge CLK)'))

    def test_geometry_unchanged(self):
        fixed=transform(self.source)
        for token in ('localparam LINES         = 128;', 'localparam LINESIZE      = 8;', 'localparam ASSOCIATIVITY = 4;'):
            self.assertEqual(fixed.count(token),1)

    def test_second_application_rejected(self):
        with self.assertRaises(ValueError):transform(transform(self.source))

    def test_partial_or_duplicate_anchor_rejected(self):
        with self.assertRaises(ValueError):transform(self.source+self.source)
        with self.assertRaises(ValueError):transform(self.source.replace('assign CPU_BUSY       =','assign CPU_BUSY =',1))


if __name__=='__main__':unittest.main()
