"""Exact source-scope tests; not processor correctness or timing evidence."""
import os
from pathlib import Path
import unittest

import extract_predicates
import prepare_probe_payload as recipe


class Scope(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(os.environ['FETCH_PROBE_PARENT']) / recipe.PAYLOAD).read_text()

    def test_exact_two_changes_and_witness(self):
        changed = recipe.transform(self.source)
        self.assertEqual(changed.replace(recipe.NEW_KIND, recipe.OLD_KIND).replace(
            recipe.NEW_ADDRESS, recipe.OLD_ADDRESS).replace(recipe.WITNESS, ''), self.source)

    def test_guards_unchanged(self):
        changed = recipe.transform(self.source)
        for name in extract_predicates.NAMES:
            self.assertEqual(extract_predicates.extract(changed, name),
                             extract_predicates.extract(self.source, name))
        self.assertEqual(changed.count('S_DECODE: translatable = fetch_overlength_probe;'), 1)

    def test_drift_reapplication_rejected(self):
        for invalid in (self.source+'\n', recipe.transform(self.source)):
            with self.assertRaises(ValueError): recipe.transform(invalid)


if __name__ == '__main__': unittest.main()
