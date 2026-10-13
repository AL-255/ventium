"""Host checks of the private local-commit build and unchanged corpus plan."""
import ast
import unittest

import build_mc_local_core as builder
import run_mc_local_core as runner


class LocalDriverTests(unittest.TestCase):
    def test_build_keeps_native_guards(self):
        text = builder.derive()
        ast.parse(text)
        for guard in (
            'len(definitions)==len(set(definitions))==152',
            "assert not {'SYNTHESIS','VTM_NO_DPI'}&set(definitions)",
            "assert stable(before['pins'])",
            "pass_fds=(9,),timeout=660",
            "assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()",
            "sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL",
        ):
            self.assertIn(guard, text)
        self.assertEqual(text.count('sorted(CHANGES)'), 2)
        self.assertNotIn('sorted(recipe.PARENTS)', text)
        self.assertIn('admit_leaf(leaf)', text)

    def test_corpus_and_coverage_are_unchanged(self):
        new, old = ast.parse(runner.derive()), ast.parse(runner.previous.derive())
        def assignments(tree, name):
            return [ast.dump(n.value) for n in ast.walk(tree)
                    if isinstance(n, ast.Assign) and any(
                        isinstance(t, ast.Name) and t.id == name for t in n.targets)]
        self.assertEqual(assignments(new, 'plan'), assignments(old, 'plan'))
        checks = lambda tree: [ast.dump(n) for n in ast.walk(tree)
                              if isinstance(n, ast.Assert) and any(
                                  isinstance(s, ast.Constant) and s.value in ('coverage', 'probe_runs')
                                  for s in ast.walk(n))]
        self.assertEqual(checks(new), checks(old))
        self.assertEqual(len(checks(new)), 2)
        text = runner.derive()
        self.assertIn("canonical_gate_passed=False", text)
        self.assertIn("standard_suite=False,hardware_acceptance=False", text)
        self.assertIn("assert started['changes'] == ['rtl/core/core_mem_chain.svh']", text)
        self.assertIn(runner.CANDIDATE, text)
        self.assertIn(runner.PARENT, text)


if __name__ == '__main__':
    unittest.main()
