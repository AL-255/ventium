#!/usr/bin/env python3
"""Fail-closed source-anchor tests, not RTL behavioral acceptance."""
import unittest
from prepare_cont_no_uop import FLAG, OLD, NEW, transform


class Recipe(unittest.TestCase):
    def test_only_admission_changes(self):
        source = '// before\n' + OLD + '\n// after\n'
        result = transform(source)
        self.assertEqual(result, '// before\n' + NEW + '\n// after\n')
        self.assertEqual(result.replace(NEW, OLD), source)

    def test_reject_reapplication(self):
        with self.assertRaises(ValueError):
            transform(transform(OLD))

    def test_reject_anchor_drift(self):
        for source in ('', OLD + OLD, OLD.replace('cycle_mode', "1'b1"), FLAG + OLD):
            with self.subTest(source=source), self.assertRaises(ValueError):
                transform(source)


if __name__ == '__main__':
    unittest.main()
