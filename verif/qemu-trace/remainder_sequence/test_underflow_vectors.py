import struct
import unittest

import underflow_vectors as vectors


class ExactUnderflow(unittest.TestCase):
    def setUp(self):
        self.rows=vectors.rows()

    def test_minimum_scaled_result_and_exact_zero(self):
        r=next(r for r in self.rows if r['label']=='normal-cancel-bit-0' and r['cw']==0x6f and r['op']==0)
        e=vectors.expected(r)
        self.assertEqual(e['value'],(0x5fc2,1<<63))
        self.assertEqual(e['status']&0x80ff,0x8090)
        self.assertTrue(e['underflow'])
        r=dict(r,b=r['a'])
        self.assertEqual(vectors.expected(r)['value'],(0,0))
        self.assertFalse(vectors.expected(r)['underflow'])

    def test_mask_and_denormal_priority(self):
        r=next(r for r in self.rows if r['label']=='minimum-denormal' and r['cw']==0x6f and r['op']==0)
        self.assertEqual(vectors.expected(r)['status']&0x80ff,0x8092)
        masked=vectors.expected(dict(r,cw=r['cw']|16))
        self.assertEqual(masked['value'],(0,1));self.assertEqual(masked['status']&0x80ff,2)
        aborted=vectors.expected(dict(r,cw=r['cw']&~2))
        self.assertTrue(aborted['operand_abort']);self.assertFalse(aborted['underflow'])
        self.assertEqual(aborted['value'],tuple(r['a']))
        self.assertEqual(aborted['status']&0x80ff,0x8082)

    def test_full_state_mutants(self):
        for r in self.rows[::47]:
            e=vectors.expected(r)
            raw=bytearray(108)
            struct.pack_into('<3I',raw,0,r['cw'],e['status'],e['tag'])
            for i,v in enumerate([e['value'],r['b'],*[(0x4000+((255+j)&255),1<<63) for j in range(2,8)]]):
                struct.pack_into('<QH',raw,28+10*i,v[1],v[0])
            self.assertEqual(vectors.check(r,raw),[])
            for index in (0,4,8,28,38,98):
                bad=raw.copy();bad[index]^=1
                self.assertTrue(vectors.check(r,bad),index)

    def test_complete_domain_and_wrap_span(self):
        self.assertEqual(len(self.rows),7104)
        exps={vectors.expected(r)['value'][0]&0x7fff for r in self.rows
              if r['label'].startswith('normal-cancel-bit-') and vectors.expected(r)['underflow']}
        self.assertEqual(exps,set(range(0x5fc2,0x6001)))
        for r in self.rows:
            self.assertFalse(r['sw']&~r['cw']&0x3f)
            vectors.expected(r)

    def test_operand_abort_does_not_grade_undefined_quotient(self):
        r=next(r for r in self.rows if r['label']=='minimum-denormal' and r['cw']==0x6d and r['op']==0)
        e=vectors.expected(r)
        self.assertTrue(e['operand_abort'])
        self.assertEqual(e['status_mask']&0x4700,0)
        self.assertEqual(e['status_mask']&0x80ff,0x80ff)


if __name__=='__main__':unittest.main()
