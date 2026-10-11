"""Source guards only; the array proof and native lookup test are separate."""
import argparse
from pathlib import Path
import unittest
from prepare_parallel_tag_lookup import OLD, NEW, PARALLEL, transform, lookup_block


class Recipe(unittest.TestCase):
    def test_exact_edit(self):
        candidate = transform(SOURCE)
        self.assertEqual(candidate.replace(NEW, OLD), SOURCE)
        self.assertEqual(candidate.count('always_ff'), SOURCE.count('always_ff'))
        self.assertEqual(candidate.count('assign mc_lookup_next ='),
                         SOURCE.count('assign mc_lookup_next ='))
        self.assertIn(PARALLEL, lookup_block(candidate))
        before, after = SOURCE.split(OLD)
        self.assertTrue(candidate.startswith(before))
        self.assertTrue(candidate.endswith(after))

    def test_parent_drift(self):
        for changed in (SOURCE+'\n', SOURCE.replace(OLD, ''), transform(SOURCE)):
            with self.assertRaises(ValueError):
                transform(changed)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    SOURCE = args.source.read_text()
    unittest.main(argv=['test_parallel_tag_lookup', *remaining])
