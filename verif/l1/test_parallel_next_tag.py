"""Exact edit/geometry checks; native source-extracted array tests are separate."""
import argparse
from pathlib import Path
import unittest

import prepare_parallel_next_tag as recipe


class Recipe(unittest.TestCase):
    def test_exact_edit(self):
        candidate = recipe.transform(SOURCE)
        before, after = SOURCE.split(recipe.OLD)
        self.assertEqual(candidate, before+recipe.NEW+after)
        self.assertEqual(candidate.replace(recipe.NEW, recipe.OLD), SOURCE)
        self.assertEqual(candidate.count('always_ff'), SOURCE.count('always_ff'))
        self.assertIn(recipe.PARALLEL, recipe.lookup_block(candidate))
        self.assertEqual(candidate.count('assign mc_lookup_next ='), SOURCE.count('assign mc_lookup_next ='))

    def test_drift(self):
        for bad in (SOURCE+'\n', SOURCE.replace(recipe.OLD, ''), recipe.transform(SOURCE)):
            with self.assertRaises(ValueError):
                recipe.transform(bad)

    def test_successor_wrap(self):
        for bits in (1,6,7,8):
            boundary = 1 << (5+bits)
            for address in (0, 31, boundary-32, boundary-1, 0xffffffe0, 0xffffffff):
                successor = (address+32) & 0xffffffff
                self.assertEqual((successor>>5) & ((1<<bits)-1),
                                 (((address>>5)+1) & ((1<<bits)-1)))
                if address >= 0xffffffe0:
                    self.assertEqual(successor>>5, 0)
                if boundary-32 <= address < boundary:
                    self.assertEqual(successor>>(5+bits), 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    SOURCE = args.source.read_text()
    unittest.main(argv=['test_parallel_next_tag', *remaining])
