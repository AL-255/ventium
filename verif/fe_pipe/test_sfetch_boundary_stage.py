import unittest
import ast
from pathlib import Path

import prepare_sfetch_boundary_stage as recipe
import run_sfetch_boundary_stage_leaf as leaf

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-core-r1/candidate')


class BoundaryStageTest(unittest.TestCase):
    def test_exact_policy_delta(self):
        for name in recipe.PARENTS:
            old = (SOURCE/name).read_text()
            changed = recipe.transform(old,name)
            with self.assertRaises(ValueError): recipe.transform(changed,name)
            if name.endswith('.sv'):
                self.assertEqual(changed.replace(recipe.STAGE,recipe.base.STAGE), recipe.base.transform(old,name))
            else:
                self.assertEqual(changed,recipe.base.transform(old,name))

    def test_mutations_and_interior_contract(self):
        self.assertIn(recipe.STAGE,leaf.fixture('positive'))
        for mode in leaf.previous.MODES:
            self.assertIn('SFETCH-INTERIOR-OK checks=12288 no_extra_clock=4096',leaf.fixture(mode))

    def test_builder_has_native_entry_point(self):
        import build_sfetch_boundary_core as builder
        module = ast.parse(Path(builder.__file__).read_text())
        entry = module.body[-1]
        self.assertIsInstance(entry,ast.If)
        self.assertEqual(ast.unparse(entry.test), "__name__ == '__main__'")
        self.assertEqual(ast.unparse(entry.body[0]),'raise SystemExit(main())')


if __name__=='__main__': unittest.main()
