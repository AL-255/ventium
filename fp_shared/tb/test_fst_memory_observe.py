import unittest
import run_fst_memory_observe as o


def case(**kwargs):
    c=dict(bits=32,exponent=0,mantissa=1<<63,sign=0,rc=0,pop=0,seed=0)
    c.update(kwargs);return c


class MemoryFSTTests(unittest.TestCase):
    def test_matrix(self):
        rows=o.cases()
        self.assertEqual(len(rows),2352)
        self.assertEqual(len({tuple(sorted(c.items())) for c in rows}),len(rows))
        self.assertTrue(all(c['pop'] for c in rows if c['bits']==80))

    def test_exact_and_tie_even(self):
        self.assertEqual(o.expected(case()),dict(value=0x3f800000,flags=0,c1=0))
        self.assertEqual(o.expected(case(mantissa=(1<<63)+(1<<39))),
                         dict(value=0x3f800000,flags=0x20,c1=0))
        self.assertEqual(o.expected(case(mantissa=(1<<63)+(3<<39))),
                         dict(value=0x3f800002,flags=0x20,c1=1))

    def test_negative_round_direction_is_magnitude(self):
        self.assertEqual(o.expected(case(mantissa=(1<<63)+1,sign=1,rc=1)),
                         dict(value=0xbf800001,flags=0x20,c1=1))
        self.assertEqual(o.expected(case(mantissa=(1<<63)+1,sign=1,rc=2)),
                         dict(value=0xbf800000,flags=0x20,c1=0))

    def test_subnormal_and_after_round_tininess(self):
        self.assertEqual(o.expected(case(exponent=-128)),dict(value=0x200000,flags=0,c1=0))
        self.assertEqual(o.expected(case(exponent=-127,mantissa=(1<<64)-1)),
                         dict(value=0x800000,flags=0x20,c1=1))

    def test_overflow_directions(self):
        self.assertEqual(o.expected(case(exponent=128)),dict(value=0x7f800000,flags=0x28,c1=1))
        self.assertEqual(o.expected(case(exponent=128,rc=3)),dict(value=0x7f7fffff,flags=0x28,c1=0))

    def test_double_precision_and_exact80(self):
        self.assertEqual(o.expected(case(bits=64)),dict(value=0x3ff0000000000000,flags=0,c1=0))
        c=case(bits=80,pop=1,seed=1)
        self.assertEqual(o.expected(c),dict(value=0x3fff8000000000000000,flags=0,c1=0))

    def test_fixture_has_real_setup_store_and_sentinel(self):
        text=o.assembly(o.cases())
        self.assertEqual(text.count('fnstenv env'),2352)
        self.assertEqual(text.count('fnsave rows+'),2352)
        self.assertIn('rows: .fill 301056,1,0xa5',text)
        for op in ('fsts','fstps','fstl','fstpl','fstpt'): self.assertIn(op+' rows+',text)


if __name__=='__main__': unittest.main()
