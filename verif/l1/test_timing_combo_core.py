#!/usr/bin/env python3
"""Validate exact composition and reject input drift before native builds."""
import argparse
from pathlib import Path
import unittest
from build_timing_combo_core import DELTAS, prepare


class Composition(unittest.TestCase):
    def test_all_three_changes(self):
        result = prepare(self.sources)
        self.assertEqual(set(result), set(DELTAS))
        self.assertTrue(all(result[n] != self.sources[n] for n in result))

    def test_each_drift_rejected(self):
        for name in self.sources:
            with self.subTest(name=name), self.assertRaises(ValueError):
                prepare(self.sources | {name: self.sources[name]+'\n'})

    def test_already_combined_rejected(self):
        with self.assertRaises(ValueError):
            prepare(prepare(self.sources))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent', type=Path, required=True)
    args = parser.parse_args()
    Composition.sources = {n: (args.parent/n).read_text() for n in DELTAS}
    unittest.main(argv=[__file__], verbosity=2)
