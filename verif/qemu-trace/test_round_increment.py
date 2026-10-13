"""Source guards and exact-oracle boundaries; native A/B tests are separate."""
from fractions import Fraction as F
from pathlib import Path
import re
import unittest

import prepare_round_increment as recipe
from run_round_increment import arithmetic_event, exact_value


class SourceGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source=Path(__file__).resolve().parents[2]/'ventium-refs/07-p5-emulation-harness/build/qemu'
        cls.original={name:(source/name).read_text() for name in recipe.PARENTS}

    def test_only_observations_added(self):
        changed=recipe.transform(self.original)
        name='include/fpu/softfloat-types.h'
        restored=re.sub(r'    /\* Ventium diagnostic derivative:.*?    bool float_round_increment;\n',
                        '',changed[name],flags=re.S)
        self.assertEqual(restored,self.original[name])
        for name in ('fpu/softfloat-parts.c.inc','fpu/softfloat.c'):
            restored=re.sub(r'^ +s->float_round_increment = (?:false|true);\n',
                            '',changed[name],flags=re.M)
            restored=restored.replace('            s->float_round_increment =\n'
                '                inc > round_mask - (p->frac_lo & round_mask);\n','')
            if name.endswith('.inc'):
                restored=restored.replace('    int exp, flags = 0;\n\n\n',
                                          '    int exp, flags = 0;\n\n')
            self.assertEqual(restored,self.original[name])

    def test_missing_extra_and_drift_refused(self):
        for name in recipe.PARENTS:
            with self.subTest(name=name):
                missing=dict(self.original); missing.pop(name)
                with self.assertRaises(ValueError): recipe.transform(missing)
                drift=dict(self.original); drift[name]+='\n'
                with self.assertRaises(ValueError): recipe.transform(drift)
        with self.assertRaises(ValueError): recipe.transform(dict(self.original,extra=''))

    def test_reapplication_refused(self):
        with self.assertRaises(ValueError): recipe.transform(recipe.transform(self.original))

    def test_ambiguous_anchor_refused(self):
        for text in ('zero','aa aa'):
            with self.assertRaises(ValueError): recipe.change(text,'aa','bb')


class ExactOracle(unittest.TestCase):
    def test_x80_decode(self):
        self.assertEqual(exact_value(16383,1<<63),1)
        self.assertEqual(exact_value(16383|0x8000,1<<63),-1)
        self.assertEqual(exact_value(0,1),F(1,1<<16445))

    def test_64bit_ties_and_directed(self):
        for sign in (-1,1):
            self.assertEqual(arithmetic_event(sign*(1+F(1,1<<64)),64,0),0)
            self.assertEqual(arithmetic_event(sign*(1+F(3,1<<64)),64,0),1)
            for rc in range(4):
                self.assertEqual(arithmetic_event(sign*(1+F(1,1<<80)),64,rc),
                                 int((rc==1 and sign<0) or (rc==2 and sign>0)))

    def test_sqrt_exact_and_ties(self):
        for p in (24,53,64):
            for rc in range(4): self.assertEqual(arithmetic_event(F(4),p,rc,True),0)
            even=1+F(1,1<<p); odd=1+F(3,1<<p)
            self.assertEqual(arithmetic_event(even*even,p,0,True),0)
            self.assertEqual(arithmetic_event(odd*odd,p,0,True),1)
            self.assertEqual(arithmetic_event(F(2),p,2,True),1)
            self.assertEqual(arithmetic_event(F(2),p,1,True),0)

    def test_x80_subnormal_and_overflow(self):
        for p in (24,53,64):
            half=F(1,1<<(16382+p))
            self.assertEqual(arithmetic_event(half,p,0),0)
            self.assertEqual(arithmetic_event(3*half,p,0),1)
            for sign in (-1,1):
                for rc in range(4):
                    self.assertEqual(arithmetic_event(F(sign*(1<<16384)),p,rc),
                                     int(rc==0 or (rc==1 and sign<0) or (rc==2 and sign>0)))


if __name__=='__main__': unittest.main()
