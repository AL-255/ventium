"""Host tests for exact build delta and unchanged eight-corpus coverage."""
import ast
import unittest

import build_prime_coherence_core as builder
import run_prime_coherence_core as runner
import run_prime_coherence_regressions as regressions


class DriverTests(unittest.TestCase):
    def test_build_contract(self):
        text=builder.derive()
        ast.parse(text)
        for check in ("assert len(files)==195",'len(definitions)==len(set(definitions))==152',
                      "assert not {'SYNTHESIS','VTM_NO_DPI'}&set(definitions)",
                      "pass_fds=(9,),timeout=660", "assert stable(before['pins'])",
                      "assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()"):
            self.assertIn(check,text)
        self.assertIn("changes={p:transformed[p] for p in CHANGES}",text)
        self.assertEqual(text.count('sorted(CHANGES)'),2)
        self.assertIn(builder.MODEL,text)

    def test_plan_and_counters(self):
        old,new=ast.parse(runner.previous.derive()),ast.parse(runner.derive())
        plan=lambda tree:[ast.dump(n.value) for n in ast.walk(tree) if isinstance(n,ast.Assign)
                          and any(isinstance(t,ast.Name) and t.id=='plan' for t in n.targets)]
        self.assertEqual(plan(old),plan(new))
        counts=lambda tree:[ast.dump(n) for n in ast.walk(tree) if isinstance(n,ast.Assert)
                            and any(isinstance(t,ast.Constant) and t.value in ('coverage','probe_runs')
                                    for t in ast.walk(n))]
        self.assertEqual(counts(old),counts(new));self.assertEqual(len(counts(new)),2)
        text=runner.derive()
        self.assertIn('canonical_gate_passed=False',text)
        self.assertIn('standard_suite=False,hardware_acceptance=False',text)
        self.assertIn(runner.PARENT,text);self.assertIn(runner.CANDIDATE,text)

    def test_extended_plan_is_unchanged(self):
        before,after=ast.parse(regressions.previous.derive()),ast.parse(regressions.derive())
        plan=lambda tree:next(ast.dump(n) for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='plan')
        self.assertEqual(plan(before),plan(after))
        text=regressions.derive()
        self.assertIn("len(done['measurements'])==1536 and len(done['deltas'])==768",text)
        self.assertIn("not verified['masks_or_goldens_or_bands_changed']",text)
        self.assertIn("canonical_gate_passed=verified['canonical_gate_passed']",text)


if __name__=='__main__':unittest.main()
