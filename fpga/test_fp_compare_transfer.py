"""Check exact two-file transfer and reject missing, drifted or extra deltas."""
import os
from pathlib import Path
import unittest

import freeze_fp_compare_rk_candidate as freeze


class TransferTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['FP_COMPARE_HARDWARE_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['FP_COMPARE_CORE']).resolve(strict=True)

    def test_exact_core_match(self):
        self.assertEqual(freeze.CHANGES, ['ventium/fp_shared/ven_fp_top.sv', 'ventium/rtl/mem/ven_l1d.sv'])
        for name in freeze.CHANGES:
            with self.subTest(name=name):
                self.assertTrue(freeze.check_delta(name, (self.parent / name).read_bytes(),
                    (self.core / name.removeprefix('ventium/')).read_bytes()))

    def test_missing_drift_and_reapplication_rejected(self):
        for name in freeze.CHANGES:
            before = (self.parent / name).read_bytes()
            after = (self.core / name.removeprefix('ventium/')).read_bytes()
            for a, b in ((before, before), (before, after + b'\n'), (before + b'\n', after), (after, after)):
                with self.subTest(name=name, a=len(a), b=len(b)):
                    with self.assertRaises(Exception): freeze.check_delta(name, a, b)

    def test_other_sources_unchanged(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv', b'a', b'a'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/other.sv', b'a', b'b')


if __name__ == '__main__': unittest.main()
