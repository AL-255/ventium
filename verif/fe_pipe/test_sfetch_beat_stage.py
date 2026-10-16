import unittest
from pathlib import Path

import prepare_sfetch_beat_stage as recipe
import run_sfetch_beat_stage_leaf as leaf
import run_sfetch_beat_checks as checks

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-core-r1/candidate')


class RecipeTest(unittest.TestCase):
    def test_scope_and_fail_closed(self):
        for name in recipe.PARENTS:
            source = (SOURCE/name).read_text()
            changed = recipe.transform(source, name)
            self.assertNotEqual(changed, source)
            with self.assertRaises(ValueError):
                recipe.transform(changed, name)
            with self.assertRaises(ValueError):
                recipe.transform(source+'\n', name)
            if name.endswith('.svh'):
                self.assertEqual(changed.replace('!sfetch_want_req && d_fetch_meta_ready',
                    '!sfetch_demand_req && d_fetch_meta_ready'), source)
            else:
                start = source.index('  assign sfetch_demand_req = ')
                end = source.index('\n`ifndef SYNTHESIS', start)
                self.assertTrue(changed.startswith(source[:start]))
                self.assertTrue(changed.endswith(source[end:]))
                self.assertIn(recipe.STAGE, changed)
                self.assertIn(recipe.WITNESS, changed)
                self.assertNotIn('sfetch_demand_addr <=', changed)

    def test_all_mutants_change_actual_stage(self):
        original = leaf.fixture('positive')
        self.assertIn(recipe.STAGE, original)
        for mode in leaf.MODES[1:]:
            self.assertNotEqual(leaf.fixture(mode), original)

    def test_check_adapters_preserve_architectural_comparisons(self):
        for mode in checks.SOURCES:
            source, changed, edits = checks.derive(mode)
            self.assertEqual(changed.count('compare.compare_func('), source.read_text().count('compare.compare_func('))
            self.assertNotIn('compare.compare_func', ''.join(old+new for old,new in edits))
            self.assertIn("--l1-axi", changed)
            self.assertIn("cycle-func", changed)


if __name__ == '__main__':
    unittest.main()
