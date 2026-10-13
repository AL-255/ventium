"""Exact-scope tests; these are not native cache or core acceptance."""
import os
from pathlib import Path
import unittest

import prepare_payload_region_hint as recipe


class PayloadRegion(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PAYLOAD_REGION_SOURCE']).resolve(strict=True)

    def test_exact_two_file_delta_and_reversal(self):
        for name in recipe.PARENTS:
            old = (self.root / name).read_text()
            new = recipe.transform(old, name)
            self.assertNotEqual(old, new)
            for before, after in reversed(recipe.edits(name)):
                self.assertEqual(new.count(after), 1)
                new = new.replace(after, before)
            self.assertEqual(old, new)

    def test_reject_drift_reapplication_and_wrong_file(self):
        for name in recipe.PARENTS:
            old = (self.root / name).read_text()
            for bad in (old + '\n', recipe.transform(old, name)):
                with self.assertRaises(ValueError):
                    recipe.transform(bad, name)
        with self.assertRaises(ValueError):
            recipe.transform('', 'rtl/core/core.sv')

    def test_original_ownership_and_ack_assertions_retained(self):
        name = 'rtl/mem/ven_l1d.sv'
        old = (self.root / name).read_text()
        new = recipe.transform(old, name)
        for marker in ('L1 primary payload cut changed an acknowledged read',
                       'PAYLOAD-CODE-HINT: changed consumed response owner',
                       'RESPONSE-PAYLOAD-DUPLICATE', 'CODE-PAYLOAD-OWNER',
                       'HIGH-WINDOW-PAYLOAD: changed valid owner'):
            self.assertEqual(new.count(marker), old.count(marker))
            self.assertGreater(old.count(marker), 0)
        # Only the payload predicate consumes the new input. Controls cannot.
        self.assertEqual(new.count('c_payload_cacheable'), 2)

    def test_complete_extent_control_and_legacy_policies_preserved(self):
        name = 'rtl/mem/ventium_l1_axi.sv'
        old = (self.root / name).read_text()
        new = recipe.transform(old, name)
        for line in old.splitlines():
            if 'assign l1d_cacheable =' in line or 'assign core_d_last =' in line:
                self.assertEqual(new.count(line), old.count(line))
        self.assertIn('EN_L2 ? l1d_cacheable : (core_d_l1c && !cr0_cd)', new)
        self.assertIn('`ifdef VEN_L1_IGNORE_CD\n  assign l1d_payload_cacheable = l1d_cacheable;', new)


if __name__ == '__main__':
    unittest.main()
