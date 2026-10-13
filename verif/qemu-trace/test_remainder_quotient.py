"""Source guards and independent quotient boundaries; native tests are separate."""
from fractions import Fraction as F
from pathlib import Path
import unittest

import prepare_remainder_quotient as recipe
from run_remainder_quotient import MASK, cases, parse, quotient, value


class RecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[2]/'ventium-refs/07-p5-emulation-harness/build/qemu'
        cls.original = {n:(source/n).read_text() for n in recipe.PARENTS}

    def test_modes_and_all_callers(self):
        changed = recipe.transform(self.original)
        text = changed['fpu/softfloat.c']
        self.assertEqual(text.count('parts_modrem(&pa, &pb, false, NULL, status)'),3)
        self.assertEqual(text.count('parts_modrem(&pa, &pb, mod, quotient, status)'),1)
        self.assertEqual(text.count('            ++quot;\n'),2)
        self.assertNotIn('mod ? quotient : NULL',text)
        self.assertEqual(text.count('    if (!mod) {\n'),2)
        self.assertIn('frac_modrem(a, b, mod, mod_quot);',changed['fpu/softfloat-parts.c.inc'])

    def test_fail_closed(self):
        for name in recipe.PARENTS:
            missing = dict(self.original)
            missing.pop(name)
            with self.assertRaises(ValueError): recipe.transform(missing)
            drift = dict(self.original)
            drift[name] += '\n'
            with self.assertRaises(ValueError): recipe.transform(drift)
        with self.assertRaises(ValueError): recipe.transform(dict(self.original,extra=''))
        with self.assertRaises(ValueError): recipe.transform(recipe.transform(self.original))
        with self.assertRaises(ValueError): recipe.change('a a','a','b')


class OracleTests(unittest.TestCase):
    def test_ties_and_neighbours(self):
        for q in range(8):
            mid = F(2*q+1,2)
            self.assertEqual(quotient(mid,1,False),q+(q&1))
            self.assertEqual(quotient(mid-F(1,1<<64),1,False),q)
            self.assertEqual(quotient(mid+F(1,1<<64),1,False),q+1)
            self.assertEqual(quotient(mid,1,True),q)

    def test_signs(self):
        for sa in (-1,1):
            for sb in (-1,1):
                self.assertEqual(quotient(sa*F(7,2),sb,False),4)
                self.assertEqual(quotient(sa*F(7,2),sb,True),3)

    def test_low_64_wrap(self):
        self.assertEqual(quotient(F(2*MASK+1,2),1,False),0)
        self.assertEqual(quotient(F(2*MASK+1,2),1,True),MASK)
        self.assertEqual(quotient(F((1<<127)+7),1,False),7)

    def test_subnormal(self):
        self.assertEqual(value(0,1),F(1,1<<16445))
        self.assertEqual(quotient(value(0,3),value(0,2),False),2)
        self.assertEqual(quotient(value(0,5),value(0,2),False),2)
        self.assertEqual(value(0x8000,3),-value(0,3))

    def test_case_coverage(self):
        rows = cases()
        self.assertEqual({r['args'][0] for r in rows},set(range(5)))
        self.assertEqual({r['args'][1:3] for r in rows if r['args'][0] == 0},
                         {(p,r) for p in range(3) for r in range(4)})
        self.assertTrue(any(r['expected_quotient'] & 7 == 7 for r in rows if r['args'][0] == 0))
        self.assertEqual(parse('0000 0000000000000000 0000 ffffffffffffffff\n'),[(0,0,0,MASK)])
        with self.assertRaises(AssertionError): parse('0 0 0')


if __name__ == '__main__': unittest.main()
