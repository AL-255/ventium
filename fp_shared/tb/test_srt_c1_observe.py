#!/usr/bin/env python3
"""Host-side checks for the independent arithmetic observation fixture."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('observe', Path(__file__).with_name('run_srt_c1_observe.py'))
observe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observe)


class OracleTests(unittest.TestCase):
    def test_exact_and_adjacent(self):
        one = observe.fx(0, 16383, 1 << 63)
        c = dict(op='sqrt', a=one)
        self.assertEqual(observe.classify(c, one), dict(c1=0, inexact=0))
        self.assertEqual(observe.classify(c, one+1), dict(c1=1, inexact=1))
        self.assertEqual(observe.classify(c, observe.fx(0, 16382, (1 << 64)-1)), dict(c1=0, inexact=1))

    def test_negative_divide_uses_magnitude(self):
        one = observe.fx(1, 16383, 1 << 63)
        three = observe.fx(0, 16384, 3 << 62)
        c = dict(op='div', a=one, b=three)
        floor = observe.fx(1, 16381, 0xaaaaaaaaaaaaaaaa)
        self.assertEqual(observe.classify(c, floor), dict(c1=0, inexact=1))
        self.assertEqual(observe.classify(c, floor+1), dict(c1=1, inexact=1))

    def test_extremes_are_exact_rational(self):
        smallest = observe.fraction(1)
        self.assertEqual(smallest.numerator, 1)
        self.assertEqual(smallest.denominator, 1 << 16445)
        largest = observe.fraction(observe.fx(0, 32766, (1 << 64)-1))
        self.assertGreater(largest, 1 << 16383)
        self.assertLess(largest, 1 << 16384)
        with self.assertRaises(AssertionError):
            observe.fraction(observe.fx(0, 32767, 1 << 63))

    def test_full_matrix_and_seeds(self):
        items = observe.cases()
        self.assertEqual(len(items), 912)
        self.assertEqual(items, observe.cases())
        for pc in (0, 2, 3):
            for rc in range(4):
                for seed in (0, 1):
                    subset = [c for c in items if (c['pc'], c['rc'], c['seed']) == (pc, rc, seed)]
                    self.assertEqual(len(subset), 38)
                    self.assertEqual({c['op'] for c in subset}, {'sqrt', 'div'})

    def test_isa_seed_and_complete_output(self):
        items = observe.cases()
        asm = observe.assembly(items)
        self.assertEqual(asm.count('fnstenv env'), 912)
        self.assertEqual(asm.count('fldenv env'), 912)
        self.assertEqual(asm.count('orw $0x0200,env+4'), 456)
        self.assertEqual(asm.count('fnstsw words+'), 1824)
        self.assertEqual(asm.count('fstpt words+'), 912)
        self.assertIn('movl $14592,%edx', asm)
        self.assertEqual(asm.count('int $0x80'), 2)


if __name__ == '__main__':
    unittest.main()
