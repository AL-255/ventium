import os
from pathlib import Path
import unittest

import prepare_remainder_exact as patch
import run_remainder_exact as run


class Remainder(unittest.TestCase):
    def test_source_scope(self):
        before=Path(os.environ['SRT_REMAINDER_PARENT']).read_text()
        after=patch.transform(before)
        with self.assertRaises(ValueError):patch.transform(after)
        with self.assertRaises(ValueError):patch.transform(before+'\n')
        # Shared iterative DIV/SQRT recurrence and final rounding are untouched.
        start='        ST_DRUN: begin';end='        ST_RRUN: begin'
        self.assertIn(start,before)
        self.assertEqual(before[before.index(start):before.index(end)],
                         after[after.index(start):after.index(end)])
        self.assertEqual(after.count('rsmall_half <= (rexpd == -17\'sd1);'),1)
        self.assertIn('rma > rmbb',after)  # strict: exact half keeps even Q=0
        self.assertEqual(after.count('else begin r = rrem;'),before.count('else begin r = rrem;'))

    def test_exact_small_and_subnormal(self):
        o=run.oracle
        pairs=[((0x3fff,0xc000000000000000),(0x4000,1<<63),(0xbffe,1<<63)),
               ((0,3),(0,2),(0x8000,1)),((0,2),(0,3),(0x8000,1)),
               ((0,1),(0,2),(0,1))]
        for a,b,expected in pairs:
            ai,bi,ri=o.aligned(a,b,expected)
            result,q=o.final(ai,bi,True)
            self.assertEqual(result,ri)
            self.assertEqual(o.step_errors(a,b,expected,o.quotient_bits(q),True),[])

    def test_coverage(self):
        rows=run.cases()
        self.assertEqual(len(rows),8448)
        self.assertEqual([r['id'] for r in rows],list(range(len(rows))))
        self.assertEqual({r['kind'] for r in rows},{0,1})
        self.assertTrue(any(r['a'][0]&0x7fff==0 for r in rows))
        self.assertTrue(any(r['b'][0]&0x7fff==0 for r in rows))


if __name__=='__main__':unittest.main()
