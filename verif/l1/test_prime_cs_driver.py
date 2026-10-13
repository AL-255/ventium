"""Lifecycle/plan guards; no whole-core qualification from source tests."""
import ast
import unittest

import build_mc_local_core
import build_prime_cs_core as build
import run_prime_coherence_core
import run_prime_cs_core as run
import run_prime_cs_regressions as regressions


def assignment(source,name):
    matches=[node for node in ast.walk(ast.parse(source)) if isinstance(node,ast.Assign)
             and any(isinstance(t,ast.Name) and t.id==name for t in node.targets)]
    assert len(matches)==1
    return ast.dump(matches[0],include_attributes=False)


class Lifecycle(unittest.TestCase):
    def test_unchanged_plan_and_coverage(self):
        before=run_prime_coherence_core.derive(); after=run.derive()
        for name in ('plan','commands','common'):
            self.assertEqual(assignment(before,name),assignment(after,name))
        for text in ("assert result['probe_runs'] == 4240",'clocks=21190336,agi=18172,ref=24352',
                     "checked['inputs_unchanged' if label == 'held' else 'pins_unchanged']"):
            self.assertIn(text,after)

    def test_exact_models_and_changed_file(self):
        source=run.derive()
        self.assertIn('PARENT_MODEL = '+repr(build.MODEL),source)
        self.assertIn("assert closed['binary_sha256'] == "+repr(run.CANDIDATE),source)
        self.assertIn("assert started['changes'] == ['rtl/core/core.sv']",source)
        self.assertIn('cs_extent_request_equality_assertion=True',source)

    def test_builder_preserves_native_lifecycle(self):
        before=build_mc_local_core.derive(); after=build.derive()
        def function(source,name):
            return ast.dump(next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef)
                                 and n.name==name),include_attributes=False)
        self.assertEqual(function(before,'build'),function(after,'build'))
        self.assertEqual(function(before,'main'),function(after,'main'))
        self.assertIn('tb_prime_cs_',after)
        self.assertIn("assert sha(source/CHANGES[0])==recipe.PRIME_PARENT",after)

    def test_extended_plan_is_unchanged(self):
        def plan(source):
            return ast.dump(next(n for n in ast.parse(source).body
                                 if isinstance(n,ast.FunctionDef) and n.name=='plan'))
        text=regressions.derive()
        self.assertEqual(plan(regressions.previous.derive()),plan(text))
        self.assertIn("len(done['measurements'])==1536 and len(done['deltas'])==768",text)
        self.assertIn("not verified['masks_or_goldens_or_bands_changed']",text)
        self.assertIn("canonical_gate_passed=verified['canonical_gate_passed']",text)


if __name__=='__main__': unittest.main()
