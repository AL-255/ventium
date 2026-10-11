#!/usr/bin/env python3
import os
from pathlib import Path
import unittest
from prepare_v_carry_payload import OLD, NEW, transform


class Recipe(unittest.TestCase):
    def setUp(self):
        self.source = Path(os.environ['V_CARRY_PARENT']).read_text()

    def test_exact_payload_edit(self):
        self.assertEqual(transform(self.source).replace(NEW, OLD), self.source)

    def test_all_other_pair_qualifiers_unchanged(self):
        before = self.source.replace(OLD, '')
        after = transform(self.source).replace(NEW, '')
        self.assertEqual(before, after)
        self.assertNotIn('pipe_pair_eff', NEW.split('always_comb')[1])

    def test_drift_rejected(self):
        for source in (self.source + '\n', self.source.replace('u_shift_cnt != 0', 'u_shift_cnt != 1')):
            with self.assertRaises(ValueError):
                transform(source)

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):
            transform(transform(self.source))


if __name__ == '__main__':
    unittest.main()
