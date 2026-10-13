"""Check the sole data-size delta and reject unrelated/missing changes."""
import os
from pathlib import Path
import unittest

import freeze_data_size_rk_candidate as freeze


class TransferTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['DATA_SIZE_HARDWARE_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['DATA_SIZE_CORE']).resolve(strict=True)

    def test_exact_core_match(self):
        self.assertEqual(freeze.CHANGES, ['ventium/rtl/core/core.sv'])
        name = freeze.CHANGES[0]
        self.assertTrue(freeze.check_delta(name, (self.parent / name).read_bytes(),
                         (self.core / 'rtl/core/core.sv').read_bytes()))

    def test_missing_drift_and_reapplication_rejected(self):
        name = freeze.CHANGES[0]
        before = (self.parent / name).read_bytes()
        after = (self.core / 'rtl/core/core.sv').read_bytes()
        for a, b in ((before, before), (before, after + b'\n'), (before + b'\n', after), (after, after)):
            with self.subTest(a=len(a), b=len(b)):
                with self.assertRaises(Exception): freeze.check_delta(name, a, b)

    def test_other_sources_unchanged(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv', b'a', b'a'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/other.sv', b'a', b'b')


if __name__ == '__main__':
    unittest.main()
