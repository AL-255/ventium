"""Guard unchanged native plans and comparisons in the model-only adapter."""
import ast
import unittest
from unittest.mock import patch

import run_intent_ready_regressions as driver


class RegressionTests(unittest.TestCase):
    def test_native_plan_and_comparisons_unchanged(self):
        original = ast.parse(driver.original.read_text())
        adapted = ast.parse(driver.derive())
        functions = lambda tree: {n.name:n for n in tree.body if isinstance(n, ast.FunctionDef)}
        before, after = functions(original), functions(adapted)
        self.assertEqual(ast.dump(before['plan']), ast.dump(after['plan']))
        # Only main's input pin construction changes, not native grading.
        for key in ('commands=plan(parent,candidate,root)', 'result.update(pins_unchanged='):
            self.assertEqual(driver.original.read_text().split(key)[1], driver.derive().split(key)[1])
        self.assertIn(driver.PARENT, driver.derive())
        self.assertIn(driver.CANDIDATE, driver.derive())

    def test_reject_lifecycle_drift(self):
        with patch.object(type(driver.original), 'read_text', return_value=driver.original.read_text()+'\n'):
            with self.assertRaisesRegex(ValueError, 'lifecycle drift'):
                driver.derive()


if __name__ == '__main__': unittest.main()
