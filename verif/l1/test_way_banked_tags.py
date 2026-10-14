"""Source guards; native full-cache equivalence is a separate required test."""
import argparse
from pathlib import Path
import unittest

import prepare_way_banked_tags as recipe


class Recipe(unittest.TestCase):
    def test_exact_reversal(self):
        candidate = recipe.transform(SOURCE)
        self.assertEqual(recipe.reverse(candidate), SOURCE)
        self.assertEqual(candidate.count('always_ff'), SOURCE.count('always_ff'))
        self.assertEqual(candidate.count('`ifdef'), SOURCE.count('`ifdef'))
        self.assertEqual(candidate.count('dc_tag_way0[fset] <= ftag;'), 1)
        self.assertEqual(candidate.count('dc_tag_way1[fset] <= ftag;'), 1)
        # Resetting valid bits still owns reset; no payload reset is introduced.
        self.assertIn('`ifndef VEN_L1D_TAG_LUTRAM\n        dc_tag[s][0]<=20\'d0;', candidate)

    def test_drift(self):
        for bad in (SOURCE+'\n', SOURCE.replace(recipe.OLD_WRITE, ''), recipe.transform(SOURCE)):
            with self.assertRaises(ValueError):
                recipe.transform(bad)

    def test_only_lutram_payload_changes(self):
        # Every original flat access is converted; the fallback two-dimensional
        # layout and all valid/LRU/data/owner operations remain byte-identical.
        self.assertEqual(len(recipe.replacements()), 16)
        changed = recipe.transform(SOURCE)
        original_nonflat = [line for line in SOURCE.splitlines() if 'dc_tag[' in line and 'dc_tag[{' not in line]
        changed_nonflat = [line for line in changed.splitlines() if 'dc_tag[' in line]
        self.assertEqual(original_nonflat, changed_nonflat)

    def test_miter_keeps_all_checks(self):
        changed = recipe.miter_fixture(FIXTURE)
        before = 'dut.dc_tag[s*2+w] !== control.dc_tag[s*2+w]'
        after = '(w == 0 ? dut.dc_tag_way0[s] : dut.dc_tag_way1[s]) !== control.dc_tag[s*2+w]'
        self.assertEqual(changed.replace(after, before), FIXTURE)
        with self.assertRaises(ValueError):
            recipe.miter_fixture(changed)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--fixture', type=Path, required=True)
    args, remaining = ap.parse_known_args()
    SOURCE, FIXTURE = args.source.read_text(), args.fixture.read_text()
    unittest.main(argv=['test_way_banked_tags', *remaining])
