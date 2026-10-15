"""Exact-parent and locality checks; native tests exercise architectural data."""
import os
from pathlib import Path
import unittest
import prepare_remainder_exceptions as recipe


class Recipe(unittest.TestCase):
    def test_drift_rejected(self):
        for name in recipe.PARENTS:
            with self.assertRaises(ValueError):recipe.transform('wrong source',name)

    def test_repeated_application_rejected(self):
        parent=Path(os.environ['SRT_REMAINDER_EXCEPTION_PARENT'])
        for name in recipe.PARENTS:
            after=recipe.transform((parent/name).read_text(),name)
            with self.assertRaises(ValueError):recipe.transform(after,name)

    def test_arithmetic_iterations_untouched(self):
        parent=Path(os.environ['SRT_REMAINDER_EXCEPTION_PARENT'])
        name='rtl/fpu/fpu_srt_div.sv';before=(parent/name).read_text();after=recipe.transform(before,name)
        anchor='        ST_DRUN: begin'
        self.assertEqual(before[before.index(anchor):],after[after.index(anchor):])
        self.assertEqual(after.count("rem_canonical(rem_input_a)"),2)
        name='fp_shared/ven_fp_top.sv';before=(parent/name).read_text();after=recipe.transform(before,name)
        # No sequencing, latency state, command readiness, or response engine
        # is changed; only classification and the committed architectural state.
        anchor='        TOP_SRT: begin'
        self.assertEqual(before[before.index(anchor):],after[after.index(anchor):])
        self.assertIn('fx_is_denormal(st_flat_o[159:80])',after)
        self.assertIn('c_write = !srt_rem_abort;',after)


if __name__=='__main__':unittest.main()
