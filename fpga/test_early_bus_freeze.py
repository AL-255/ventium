"""Reject absent, extra or wrong early-payload source changes."""
from pathlib import Path
import unittest

import freeze_early_bus_rk_candidate as freeze

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Freeze(unittest.TestCase):
    def test_exact_source_contract(self):
        name='ventium/'+freeze.native.recipe.FILE
        before=(ROOT/'decode-bus-fpga-r1'/name).read_bytes()
        after=(ROOT/'early-bus-core-r1/candidate'/freeze.native.recipe.FILE).read_bytes()
        self.assertTrue(freeze.check_delta(name,before,after))
        for bad in (before,after+b'\n'):
            with self.assertRaises(Exception): freeze.check_delta(name,before,bad)
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/core/core.sv',b'a',b'b')
        self.assertFalse(freeze.check_delta('unchanged',b'a',b'a'))

    def test_strict_profile_preserved(self):
        self.assertIn('simulator_defines=157, added_defines=[]',freeze.text)
        self.assertIn('len(hw) == len(set(hw)) == 159',freeze.text)
        self.assertIn("set(hw)-{'SYNTHESIS', 'VTM_NO_DPI'} == set(defs)",freeze.text)


if __name__=='__main__': unittest.main()
