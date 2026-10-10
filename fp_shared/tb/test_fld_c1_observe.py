#!/usr/bin/env python3
import unittest
from pathlib import Path
from prepare_fld_c1 import transform
from run_fld_c1_observe import cases, expected, assembly

class LoadC1Tests(unittest.TestCase):
    def test_complete_matrix(self):
        rows=cases()
        self.assertEqual(len(rows),1216)
        self.assertEqual(len({tuple(sorted(c.items())) for c in rows}),len(rows))
        for c in rows:
            want=expected(c)
            self.assertEqual(bool(want['fstat']&0x200),c['shape']=='overflow')
            self.assertEqual(want['fstat']&0x20,c['sticky'])
            self.assertEqual(want['top'],(c['top']-1)&7 if c['masked'] or c['shape']=='normal' else c['top'])

    def test_seed_does_not_define_expected_result(self):
        for c in cases():
            self.assertEqual(expected(c),expected(dict(c,seed=1-c['seed'])))

    def test_real_isa_initialization_and_observation(self):
        rows=cases();text=assembly(rows)
        self.assertEqual(text.count('fldenv env\n'),len(rows))
        self.assertEqual(text.count('fnsave rows+'),len(rows))
        self.assertIn('incl %esi\nincl %edi',text)

    def test_repair_scope_and_order(self):
        source=(Path(__file__).resolve().parents[1]/'ven_fp_top.sv').read_text()
        fixed=transform(source)
        self.assertIn("if (c_push) begin\n        c_status = 1'b1;",fixed)
        self.assertLess(fixed.index('// P54 table 6-4'),fixed.index('      if (issue_stack_fault) begin'))
        start=fixed.index('// P54 table 6-4')-6
        end=fixed.index('      // Stack faults override',start)
        self.assertEqual(fixed[:start]+fixed[end:],source)
        with self.assertRaises(ValueError):transform(fixed)
        with self.assertRaises(ValueError):transform(source+source)
        with self.assertRaises(ValueError):transform('')

if __name__=='__main__':unittest.main()
