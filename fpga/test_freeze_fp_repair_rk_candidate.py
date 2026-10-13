"""Check the entire eight-file hardware composition and deny unrelated edits."""
import os
from pathlib import Path
import unittest

import freeze_fp_repair_rk_candidate as freeze
import fp_repair_hardware as hardware


class HardwareTransferTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['FP_REPAIR_HARDWARE_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['FP_REPAIR_CORE']).resolve(strict=True)

    def test_exact_eight_file_composition(self):
        self.assertEqual(len(hardware.CHANGES), 8)
        for name in hardware.CHANGES:
            with self.subTest(name=name):
                before = (self.parent / 'ventium' / name).read_bytes()
                after = (self.core / name).read_bytes()
                self.assertTrue(freeze.check_delta('ventium/' + name, before, after))
                with self.assertRaises(Exception): freeze.check_delta('ventium/' + name, before, before)
                with self.assertRaises(Exception): freeze.check_delta('ventium/' + name, before, after + b'\n')

    def test_unreviewed_file_rejected(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/unknown.sv', b'a', b'a'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/unknown.sv', b'a', b'b')


if __name__ == '__main__':
    unittest.main()
