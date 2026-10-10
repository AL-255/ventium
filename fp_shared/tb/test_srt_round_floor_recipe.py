"""Host transformation guards; the RTL value/latency miter is separate."""
from pathlib import Path
import unittest

import prepare_srt_round_floor as p


class Recipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(__file__).resolve().parents[2].joinpath(
            'rtl/fpu/fpu_srt_div.sv').read_text()

    def test_only_three_exact_hunks(self):
        changed = p.transform(self.source)
        restored = changed.replace(p.NEW, p.OLD).replace(
            '    floor_msb = msb;                              // before the independent PC64 round\n', '').replace(
            '  int                  msb, floor_msb, extra;', p.DECL)
        self.assertEqual(restored, self.source)

    def test_entire_sequential_logic_and_interface_unchanged(self):
        changed = p.transform(self.source)
        self.assertEqual(changed[changed.rindex('  always_ff'):], self.source[self.source.rindex('  always_ff'):])
        self.assertEqual(changed[:changed.index(p.DECL.replace('msb, extra', 'msb, floor_msb, extra'))],
                         self.source[:self.source.index(p.DECL)])

    def test_floor_before_carry_and_borrow_before_replacement(self):
        changed = p.transform(self.source)
        self.assertLess(changed.index('floor_msb = msb;'), changed.index('    extra   = msb - 63;'))
        self.assertIn("if (!keepf[63]) begin\n        keepf =", changed)
        self.assertNotIn('if (resid_neg && !keepf[63])', changed)

    def test_all_missing_and_ambiguous_anchors_refused(self):
        for anchor in (p.DECL, p.SCAN, p.OLD):
            for wrong in (self.source.replace(anchor, ''), self.source+'\n'+anchor):
                with self.subTest(anchor=anchor), self.assertRaises(ValueError):
                    p.transform(wrong)

    def test_repeat_refused(self):
        with self.assertRaises(ValueError):
            p.transform(p.transform(self.source))


if __name__ == '__main__':
    unittest.main()
