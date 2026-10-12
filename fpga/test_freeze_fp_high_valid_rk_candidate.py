"""Scope tests for the three-file hardware export; no simulator is launched."""
import unittest
from unittest.mock import patch

import freeze_fp_high_valid_rk_candidate as freeze
from freeze_rk_candidate import FreezeError


class DeltaTests(unittest.TestCase):
    def test_exact_three_transformations(self):
        self.assertEqual(freeze.CHANGES, [
            'ventium/rtl/core/core.sv', 'ventium/rtl/mem/ven_l1d.sv',
            'ventium/rtl/mem/ventium_l1_axi.sv'])
        for name in freeze.CHANGES:
            with patch.object(freeze.native.recipe, 'transform', return_value='expected') as transform:
                self.assertTrue(freeze.check_delta(name, b'old', b'expected'))
                transform.assert_called_once_with('old', name.removeprefix('ventium/'))

    def test_missing_and_extra_deltas_rejected(self):
        for name in freeze.CHANGES:
            with self.assertRaises(FreezeError): freeze.check_delta(name, b'old', b'old')
        with self.assertRaises(FreezeError):
            freeze.check_delta('ventium/rtl/core/issue_uv.sv', b'old', b'changed')
        self.assertFalse(freeze.check_delta('ventium/rtl/core/issue_uv.sv', b'old', b'old'))

    def test_wrong_transformation_rejected(self):
        for name in freeze.CHANGES:
            with patch.object(freeze.native.recipe, 'transform', return_value='expected'):
                with self.assertRaises(FreezeError): freeze.check_delta(name, b'old', b'wrong')

    def test_source_hash_guard_propagates(self):
        for name in freeze.CHANGES:
            with self.assertRaisesRegex(ValueError, 'predecessor drift'):
                freeze.check_delta(name, b'not the pinned parent', b'changed')


if __name__ == '__main__': unittest.main()
