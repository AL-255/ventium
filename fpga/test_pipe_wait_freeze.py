"""Require the exact private wait change and the full RK feature set."""
from pathlib import Path
import unittest

import freeze_pipe_wait_rk_candidate as freeze

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Freeze(unittest.TestCase):
    def test_exact_delta_and_reject_unreviewed(self):
        name = 'ventium/'+freeze.native.recipe.FILE
        before = (ROOT/'demand-size-fpga-r1'/name).read_bytes()
        after = (ROOT/'pipe-wait-core-r1/candidate'/freeze.native.recipe.FILE).read_bytes()
        self.assertTrue(freeze.check_delta(name, before, after))
        for bad in (before, after+b'\n'):
            with self.assertRaises(Exception):
                freeze.check_delta(name, before, bad)
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/core/core_bus_driver.svh', b'a', b'b')
        self.assertFalse(freeze.check_delta('unchanged', b'a', b'a'))

    def test_original_profile_and_qualification(self):
        self.assertIn('simulator_defines=157, added_defines=[]', freeze.text)
        self.assertIn('len(hw) == len(set(hw)) == 159', freeze.text)
        self.assertIn("set(hw)-{'SYNTHESIS', 'VTM_NO_DPI'} == set(defs)", freeze.text)
        self.assertIn("qualification='UNQUALIFIED'", freeze.text)
        self.assertIn('standard_suite=False, hardware_acceptance=False', freeze.text)


if __name__ == '__main__':
    unittest.main()
