"""Host checks reject missing-DE, unmasked overwrite and wrong priority."""
import struct
import unittest
import state_vectors as v
import prepare_exception


def saved(r, value=None, flags=None):
    data=bytearray(108)
    status=(r['sw'] & ~0x4700) | v.flags(r)
    if v.flags(r) & ~r['cw'] & 3:status |= 0x8080
    if flags is not None:status=flags
    struct.pack_into('<3I',data,0,r['cw'],status,r['tag'])
    for i,x in enumerate((r['a'],r['b'],*[(0x4000+((255+j)&255),1<<63) for j in range(2,8)])):
        if i==0 and value is not None:x=value
        struct.pack_into('<QH',data,28+10*i,x[1],x[0])
    return bytes(data)


class ExceptionState(unittest.TestCase):
    def row(self,an,bn,mask=0x3f):
        return next(r for r in v.rows() if r['names']==[an,bn] and r['cw']&0x3f==mask and r['sw']==0)

    def test_matrix(self):
        rows=v.rows();self.assertEqual(len(rows),9552)
        self.assertTrue(all(r['cw']&0x10 for r in rows))
        self.assertEqual({r['sw']>>11&7 for r in rows},{0,3,7})
        self.assertEqual({r['cw']>>8&3 for r in rows},{0,2,3})
        self.assertEqual({r['cw']>>10&3 for r in rows},set(range(4)))

    def test_de_mutant(self):
        r=self.row('tiny','two');good=saved(r)
        self.assertFalse(v.check_native(r,good))
        self.assertIn('exception_priority',v.check_native(r,saved(r,flags=0)))
        self.assertIn('status',v.compare(r,good,saved(r,flags=0)))

    def test_abort_mutant(self):
        r=self.row('small','tiny',0x3d)
        self.assertFalse(v.check_native(r,saved(r)))
        self.assertIn('unmasked_destination',v.check_native(r,saved(r,value=(0,0))))
        self.assertIn('stack_payloads',v.compare(r,saved(r),saved(r,value=(0,0))))

    def test_priority(self):
        for a,b,expected in (('tiny','two',2),('qnan','tiny',0),('snan','tiny',1),
                             ('unnormal','qnan',1),('inf','tiny',1),('tiny','zero',1)):
            self.assertEqual(v.flags(self.row(a,b)),expected)
        self.assertTrue(all(v.flags(r)==0x41 for r in v.rows() if r['names'][0]=='empty'))

    def test_undefined_flags(self):
        r=self.row('small','zero',0x3e)
        self.assertFalse(v.status_mask(r,0x8081)&0x4700)
        r=self.row('two','small')
        self.assertEqual(v.status_mask(r,0)&0x4700,0x4700)
        self.assertEqual(v.status_mask(r,0x400)&0x4700,0x400)

    def test_parent_drift(self):
        with self.assertRaises(ValueError):prepare_exception.transform('wrong parent')


if __name__=='__main__':unittest.main()
