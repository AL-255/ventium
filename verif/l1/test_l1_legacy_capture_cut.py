#!/usr/bin/env python3
"""Exact-parent fail-closed checks; the RTL miter supplies behavioral evidence."""
import hashlib
import os
from pathlib import Path
import unittest

from prepare_l1_legacy_capture_cut import HEAD, PARENT_SHA, transform


class Recipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old = Path(os.environ['L1_CAPTURE_PARENT']).read_text()

    def test_parent_and_preserved_mux(self):
        self.assertEqual(hashlib.sha256(self.old.encode()).hexdigest(), PARENT_SHA)
        new = transform(self.old)
        self.assertEqual(new.count(HEAD + '                     do_rd_cap_legacy;'), 1)
        self.assertEqual(new.count('&& do_rd_cap_legacy'), 2)
        self.assertEqual(new.count('assign do_rd_cap_legacy ='), 1)

    def test_repeat_rejected(self):
        with self.assertRaises(ValueError):
            transform(transform(self.old))

    def test_guard_drift_rejected(self):
        for guard in ('!mc_lookup_next', '!stream_path', '!rd_armed', '!snoop_inv_valid'):
            with self.subTest(guard=guard), self.assertRaises(ValueError):
                transform(self.old.replace(guard, "1'b1", 1))

    def test_capture_drift_rejected(self):
        with self.assertRaises(ValueError):
            transform(self.old.replace('mc_capture_next && !mc_prime_window_reuse', 'mc_capture_next'))


if __name__ == '__main__':
    unittest.main()
