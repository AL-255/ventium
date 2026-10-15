"""Source-owner contract tests; no timing or full-system acceptance claim."""
import os
from pathlib import Path
import unittest

import prepare_fetch_metadata_owner as recipe


class OwnerTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(os.environ['FETCH_METADATA_PARENT']).read_text()

    def test_only_instance_replacement(self):
        changed = recipe.transform(self.source)
        prefix, suffix = self.source.split(recipe.instance(self.source))
        self.assertTrue(changed.startswith(prefix))
        self.assertTrue(changed.endswith(suffix))
        self.assertEqual(changed.count('decode_stages u_fetch_metadata ('), 1)
        for bad in (self.source+'\n', changed):
            with self.assertRaises(ValueError): recipe.transform(bad)

    def test_buffered_metadata_and_unchanged_semantics(self):
        changed = recipe.transform(self.source)
        secondary = changed.split('  decode_stages u_fetch_metadata (')[1].split('\n  );')[0]
        self.assertNotIn('refdecode_ibuf', secondary)
        self.assertIn('.ibuf          (ibuf)', secondary)
        for name in recipe.FIELDS:
            self.assertIn('(' + name + ')', secondary)
            self.assertIn('assert (' + name + ' === live_' + name + ')', changed)
        self.assertIn('.d_len         ()', secondary)
        primary = recipe.instance(changed)
        for name in recipe.FIELDS:
            self.assertIn('(live_' + name + ')', primary)
        for name in ('d_len', 'd_ea', 'd_kind', 'd_unknown', 'd_f_mem_read'):
            self.assertIn('(' + name + ')', primary)


if __name__ == '__main__': unittest.main()
