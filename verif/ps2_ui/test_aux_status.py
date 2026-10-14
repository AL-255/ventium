"""Recipe/coverage controls; actual RTL execution is run_aux_status.py."""
import hashlib
from pathlib import Path
import unittest

import prepare_aux_status as recipe
import run_aux_status as gate


class AuxStatusTests(unittest.TestCase):
    def setUp(self):
        self.source = (gate.REPO/(gate.REL+'soc/ps2.v')).read_text()

    def test_exact_source_and_one_line_delta(self):
        self.assertEqual(hashlib.sha256(self.source.encode()).hexdigest(), recipe.PARENT)
        fixed = recipe.transform(self.source)
        self.assertEqual(fixed.replace(recipe.NEW, recipe.OLD), self.source)
        self.assertEqual(sum(a != b for a, b in zip(self.source.splitlines(), fixed.splitlines())), 1)

    def test_drift_and_reapplication_refused(self):
        for source in (self.source+'\n', recipe.transform(self.source)):
            with self.assertRaises(ValueError):
                recipe.transform(source)

    def test_test_only_variants(self):
        for name in ('parent', 'fixed', 'zero', 'one'):
            value = recipe.variant(self.source, name)
            self.assertEqual(value.count('module ps2_aux_'+name+'\n'), 1)
        self.assertIn(recipe.OLD, recipe.variant(self.source, 'parent'))
        self.assertIn(recipe.NEW, recipe.variant(self.source, 'fixed'))

    def test_matrix_is_unique_and_has_real_io_controls(self):
        cases = list(gate.matrix())
        self.assertEqual(len(cases), 496)
        self.assertEqual(len(set(cases)), len(cases))
        for scenario in range(7):
            self.assertTrue(any(c[0] == scenario for c in cases))
        self.assertEqual({c[2] for c in cases}, {32, 64, 1875, 2917})
        self.assertEqual({c[3] for c in cases}, {0, 1, 7, 31})
        self.assertEqual(set(gate.PROFILES), {(), ('VEN_KBC_FAST',),
                         ('VEN_KBD_AUTOACK',), ('VEN_KBC_FAST', 'VEN_KBD_AUTOACK')})


if __name__ == '__main__':
    unittest.main()
