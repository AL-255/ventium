"""Exact source scope and two-state arithmetic proof; no hardware speed claim."""
import os
from pathlib import Path
import subprocess
import unittest

import prepare_fetch_fragment_extent as recipe


class Checks(unittest.TestCase):
    def test_exact_source_scope(self):
        source = Path(os.environ['FETCH_FRAGMENT_PARENT']).read_text()
        changed = recipe.transform(source)
        self.assertEqual(changed.replace(recipe.NEW, recipe.OLD), source)
        self.assertEqual(recipe.fetch_size(changed), recipe.fetch_size(source))
        for bad in (source+'\n', changed):
            with self.assertRaises(ValueError):
                recipe.transform(bad)

    def test_symbolic_identity_and_negative_controls(self):
        for mutant in (None, 'no-exclusion', 'fixed-width', 'lost-page-clamp'):
            with self.subTest(mutant=mutant):
                result = subprocess.run(['/usr/bin/z3', '-in', '-smt2'],
                    input=recipe.symbolic(mutant), text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'unsat' if mutant is None else 'sat')

    def test_actual_fetch_bus_is_read_only(self):
        source = Path(os.environ['FETCH_FRAGMENT_BUS_PARENT']).read_text()
        self.assertIn('bd_req = sfetch_demand_req;', recipe.fetch_bus(source))
        with self.assertRaises(ValueError):
            recipe.fetch_bus(source.replace('bd_req = sfetch_demand_req;', "bd_we=1'b1;"))


if __name__ == '__main__':
    unittest.main()
