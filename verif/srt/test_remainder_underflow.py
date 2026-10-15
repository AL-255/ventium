"""Recipe locality and owner checks, separate from native instruction tests."""
import os
from pathlib import Path
import struct
import unittest
import prepare_remainder_underflow as recipe
import run_remainder_underflow as run


class Recipe(unittest.TestCase):
    def source(self, name):
        return (Path(os.environ['SRT_REMAINDER_UNDERFLOW_PARENT'])/name).read_text()

    def test_exact_parent_and_single_application(self):
        for name in recipe.PARENTS:
            with self.assertRaises(ValueError): recipe.transform('drift', name)
            after = recipe.transform(self.source(name), name)
            with self.assertRaises(ValueError): recipe.transform(after, name)

    def test_shared_recurrence_unchanged(self):
        name = 'rtl/fpu/fpu_srt_div.sv'; before = self.source(name)
        after = recipe.transform(before, name)
        start = '        ST_DRUN: begin'; stop = '        ST_RNORM: begin'
        self.assertEqual(before[before.index(start):before.index(stop)],
                         after[after.index(start):after.index(stop)])
        self.assertEqual(after.count('function automatic logic [6:0] rem_clz64'),
                         before.count('function automatic logic [6:0] rem_clz64'))
        self.assertEqual(after.count("reb <= 17'sd1;"), 2)
        self.assertEqual(after.count('rum <= rem_underflow_mask;'), 1)
        self.assertIn('e <= 0 && !rum', after)
        self.assertNotIn('e <= 0 && !rem_underflow_mask', after)

    def test_status_priority_and_nonshared_scope(self):
        name = 'fp_shared/ven_fp_top.sv'; after = recipe.transform(self.source(name), name)
        self.assertLess(after.index("(srt_result[81] ? 16'h0010"),
                        after.index('        if (srt_rem_abort)'))
        self.assertIn('c_write = !srt_rem_abort;', after)
        self.assertIn('(srt_result[81] && !srt_rem_abort)', after)
        name = 'rtl/core/core.sv'; after = recipe.transform(self.source(name), name)
        self.assertEqual(after.count(".rem_underflow_mask(1'b1)"), 1)

    def test_infinite_divisor_oracle_and_mutants(self):
        rows = run.infinite_divisor_rows()
        underflows = 0
        for r in rows:
            finite = dict(r, b=(0x4000 | (r['b'][0]&0x8000), 1<<63))
            e = run.underflow_vectors.expected(finite)
            underflows += e['underflow']
            raw = bytearray(108)
            struct.pack_into('<3I',raw,0,r['cw'],e['status'],e['tag'])
            values = [e['value'],r['b'],*[(0x4000+((255+j)&255),1<<63) for j in range(2,8)]]
            for i,v in enumerate(values): struct.pack_into('<QH',raw,28+10*i,v[1],v[0])
            self.assertEqual(run.check_infinite(r,raw), [])
            for index in (0,4,8,28,38,98):
                bad = raw.copy(); bad[index] ^= 1
                self.assertTrue(run.check_infinite(r,bad), (r,index))
        self.assertEqual(underflows,72)


if __name__ == '__main__': unittest.main()
