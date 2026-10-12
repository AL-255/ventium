"""Exact export-delta tests; no native build or hardware claims."""
import unittest
from unittest.mock import patch

import freeze_backing_pair_payload_rk_candidate as freeze
from freeze_rk_candidate import FreezeError


class DeltaTests(unittest.TestCase):
    def test_exact_two_transformations(self):
        self.assertEqual(freeze.CHANGES,[
            'ventium/3rd-party/ao486_MiSTer/rtl/soc/dma.v','ventium/rtl/mem/ven_l1d.sv'])
        for name in freeze.CHANGES:
            with patch.object(freeze.native.recipe,'transform',return_value='expected') as transform:
                self.assertTrue(freeze.check_delta(name,b'old',b'expected'))
                transform.assert_called_once_with('old',name.removeprefix('ventium/'))

    def test_missing_extra_wrong_deltas(self):
        for name in freeze.CHANGES:
            with self.assertRaises(FreezeError):freeze.check_delta(name,b'old',b'old')
            with patch.object(freeze.native.recipe,'transform',return_value='expected'):
                with self.assertRaises(FreezeError):freeze.check_delta(name,b'old',b'wrong')
        for name in ('ventium/rtl/core/issue_uv.sv','ventium/rtl/mem/ven_axi_master.sv',
                     'ventium/3rd-party/ao486_MiSTer/rtl/soc/ps2.v'):
            with self.assertRaises(FreezeError):freeze.check_delta(name,b'old',b'changed')
            self.assertFalse(freeze.check_delta(name,b'old',b'old'))

    def test_source_hash_guard(self):
        for name in freeze.CHANGES:
            with self.assertRaisesRegex(ValueError,'predecessor drift'):
                freeze.check_delta(name,b'not the pinned parent',b'changed')


if __name__=='__main__':unittest.main()
