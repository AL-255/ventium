import os
from pathlib import Path
import unittest
import prepare
import vectors


class Repair(unittest.TestCase):
    def test_exact_sources_and_scope(self):
        source=Path(os.environ['FRNDINT_PARENT'])/'candidate'
        for name in prepare.PARENTS:
            old=(source/name).read_text();new=prepare.transform(old,name)
            self.assertNotEqual(old,new)
            with self.assertRaises(ValueError): prepare.transform(new,name)
            with self.assertRaises(ValueError): prepare.transform(old+'\n',name)
        pkg=prepare.transform((source/'rtl/fpu/fpu_x87_pkg.sv').read_text(),'rtl/fpu/fpu_x87_pkg.sv')
        self.assertEqual(pkg.count('function automatic logic [65:0] fx_round_int_mag('),1)
        self.assertEqual(pkg.count('quantized = fx_round_int_mag(v, rc);'),1)
        misc=prepare.transform((source/'fp_shared/ven_fp_misc.sv').read_text(),'fp_shared/ven_fp_misc.sv')
        self.assertIn('integral = fx_from_int($signed(ri[63:0]), 2\'b11);',misc)
        self.assertIn('value <= {fx_sign(a_q), integral[78:0]};',misc)
        for arm,next_arm in (('FX_FST_M32:', 'FX_FST_M64:'),('FX_FIST_M16,','FX_FRNDINT:'),
                             ('FX_FSCALE:','default:')):
            a=(source/'fp_shared/ven_fp_misc.sv').read_text()
            self.assertEqual(a[a.index(arm):a.index(next_arm,a.index(arm))],
                             misc[misc.index(arm):misc.index(next_arm,misc.index(arm))])

    def test_exact_oracle_edges(self):
        r=dict(hi=0x403d,m=(1<<64)-1,cw=0x037f,sw=0,kind=0,tag=0)
        self.assertEqual(vectors.finite_result(r),(0x403e8000000000000000,0x220))
        r['hi']|=0x8000
        self.assertEqual(vectors.finite_result(r),(0xc03e8000000000000000,0x220))
        r.update(hi=0x3ffe,m=1<<63)
        self.assertEqual(vectors.finite_result(r),(0,0x20))
        r.update(hi=0xbffe,cw=0x077f)
        self.assertEqual(vectors.finite_result(r),(0xbfff8000000000000000,0x220))


if __name__=='__main__': unittest.main()
