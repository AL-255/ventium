import unittest
from pathlib import Path
from prepare_fld_c1 import transform as direct_loads
from prepare_zero_c1 import transform
from run_zero_c1_observe import cases, expected, assembly, packed_bcd, real80, BCD

class ZeroC1(unittest.TestCase):
    def test_matrix_and_seed_independence(self):
        rows=cases()
        self.assertEqual(len(rows),3906)
        self.assertEqual(len(rows),len({tuple(sorted(c.items())) for c in rows}))
        for c in rows:
            want=expected(c)
            self.assertEqual(want,expected(dict(c,seed=1-c['seed'])))
            self.assertEqual(bool(want['fstat']&0x200),c.get('shape')=='overflow')
            self.assertEqual(want['fstat']&0x20,c['sticky'])

    def test_exact_decimal_and_signed_zero(self):
        for number,sign in BCD:
            bcd=packed_bcd(number,sign)
            self.assertEqual(sum(((bcd>>(4*i))&15)*10**i for i in range(18)),number)
            self.assertEqual(bcd>>79,sign)
        self.assertEqual(real80(0,1),1<<79)
        for n in (-1,10**18):
            with self.assertRaises(AssertionError):packed_bcd(n,0)

    def test_isa_fixture(self):
        rows=cases();text=assembly(rows)
        self.assertEqual(text.count('fldenv env\n'),len(rows))
        self.assertEqual(text.count('fnsave rows+'),len(rows))
        self.assertIn('incl %esi\nincl %edi',text)
        for c in rows:
            if c['op']=='fbld' and c['shape']=='normal':
                self.assertEqual(expected(c)['top'],(c['top']-1)&7)

    def test_recipe_fail_closed(self):
        source=direct_loads((Path(__file__).resolve().parents[1]/'ven_fp_top.sv').read_text())
        fixed=transform(source)
        self.assertIn("c_push_data = bcd_load_result;\n      // Valid packed",fixed)
        self.assertEqual(fixed.count('c_status_data[9]'),source.count('c_status_data[9]')+1)
        self.assertLess(fixed.index('// P54 table 6-4 also'),fixed.index('      if (issue_stack_fault) begin'))
        self.assertIn('bcd_load_start  = 1\'b0;',fixed)
        for bad in ('',fixed,source+source):
            with self.assertRaises(ValueError):transform(bad)

if __name__=='__main__':unittest.main()
