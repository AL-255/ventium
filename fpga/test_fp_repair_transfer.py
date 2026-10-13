"""Byte-exact composition and rejection tests for the full-PC transfer."""
import os
from pathlib import Path
import unittest

import fp_repair_transfer as recipe


class TransferTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['FP_REPAIR_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['FP_REPAIR_CORE']).resolve(strict=True)

    def test_exact_composition(self):
        self.assertEqual(len(recipe.PARENTS), 4)
        for name in recipe.PARENTS:
            with self.subTest(name=name):
                text = (self.parent / name).read_text()
                self.assertEqual(recipe.transform(text, name), (self.core / name).read_text())

    def test_reapplication_and_drift_rejected(self):
        for name in recipe.PARENTS:
            with self.subTest(name=name):
                text = (self.parent / name).read_text()
                with self.assertRaises(ValueError): recipe.transform(text + '\n', name)
                with self.assertRaises(ValueError): recipe.transform(recipe.transform(text, name), name)

    def test_unreviewed_file_rejected(self):
        with self.assertRaises(ValueError): recipe.transform('module unknown; endmodule', 'rtl/unknown.sv')


if __name__ == '__main__':
    unittest.main()
