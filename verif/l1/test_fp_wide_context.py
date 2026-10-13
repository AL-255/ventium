"""Scope/source-obligation/driver checks, separate from native RTL results."""
import ast
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import prepare_fp_wide_context as recipe
import prove_fp_wide_context as proof
import run_fp_wide_context_leaf as leaf
import run_fp_wide_context_cache as cache
import build_fp_wide_context_core as build
import run_fp_wide_context_core as core
import run_fp_wide_context_regressions as regressions


class WideContext(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(os.environ['FP_WIDE_CONTEXT_SOURCE']).resolve(strict=True)
        cls.inputs = {p: (root/p).read_text() for p in recipe.PARENTS | recipe.OFFER_PINS}

    def test_exact_delta_reversible(self):
        changed = leaf.source_scope(self.inputs)
        self.assertEqual(len(changed), 4)
        for path, new in changed.items():
            old = self.inputs[path]
            for before, after in reversed(recipe.edits(old, path)):
                self.assertEqual(new.count(after), 1)
                new = new.replace(after, before)
            self.assertEqual(new, old)

    def test_all_offer_headers_pinned(self):
        for path in recipe.PARENTS | recipe.OFFER_PINS:
            with self.assertRaises(ValueError):
                recipe.validate_sources(dict(self.inputs, **{path: self.inputs[path]+'\n'}))
        with self.assertRaises(ValueError):
            recipe.transform('', 'rtl/not_a_target.sv')

    def test_state_domination_and_parser_fail_closed(self):
        checked = proof.audit_guards(self.inputs)
        self.assertIn('S_FLOAD', checked['enum_states'])
        self.assertIn('S_PIPE', checked['enum_states'])
        self.assertEqual(proof.conjuncts('a && (b || c) && fn({d,e})'),
                         ['a', '(b || c)', 'fn({d,e})'])
        for expression in ('a || b', 'a && (b || c', 'a && )b(', 'a &&'):
            with self.assertRaises(AssertionError):
                proof.conjuncts(expression)
        mutated = dict(self.inputs)
        path = 'rtl/core/core_mem_chain.svh'
        mutated[path] = mutated[path].replace('mc_prime_base && mc_prepare_ok',
                                             'mc_prime_base || mc_prepare_ok')
        with self.assertRaises(AssertionError):
            proof.audit_guards(mutated)

    def test_old_simulation_witnesses_retained(self):
        changed = leaf.source_scope(self.inputs)
        for path, names in (
            ('rtl/core/core.sv', ('fp_load64_take_before_high_valid_cut',
                                 'fp_shared_load_cmd_before_high_valid_cut')),
            ('rtl/mem/ven_l1d.sv', ('c_rdata_hi_valid_before_high_valid_cut',)),
            ('rtl/mem/ventium_l1_axi.sv', ('core_rdata_hi_valid_before_high_valid_cut',)),
        ):
            for name in names:
                self.assertEqual(recipe.assignment(changed[path], name),
                                 recipe.assignment(self.inputs[path], name))

    def test_full_cache_and_private_build_guards(self):
        text = cache.derive()
        ast.parse(text)
        for marker in ('admit_proof(proof)', 'len(defines)==152', 'run_fresh_pair_capture()',
                       'c_pair_intent_ready=1', 'miter.miter_fixture(tb,False,True)',
                       "for mutant in (False,True)", 'FP-WIDE-CACHE-OK',
                       'dut.shadow_line_q !== control.shadow_line_q', 'pass_fds=(9,)',
                       'whole_core=False', 'hardware_acceptance=False'):
            self.assertIn(marker, text)
        text = build.derive()
        old = (build.HERE/'build_fp_high_valid_core.py').read_text()
        self.assertEqual(text[text.index('def build(root):'):text.index('def main():')],
                         old[old.index('def build(root):'):old.index('def main():')])
        for marker in ("host=root/('tb_fp_wide_context_'", 'len(files)==195',
                       'recipe.validate_sources', 'len(recipe.PARENTS)==4',
                       'len(definitions)==len(set(definitions))==152',
                       'pass_fds=(9,)', 'canonical_gate_passed=False'):
            self.assertIn(marker, text)
        with patch.object(build, 'BASE_SHA', '0'*64):
            with self.assertRaises(ValueError):
                build.derive()

    def test_architectural_and_cycle_plan_unchanged(self):
        text = core.derive()
        old = (core.HERE/'run_pair_intent_core.py').read_text()
        for start, end in (('    common = ', '    assert stable(pins)'),
                           ('    try:', "if __name__ == '__main__':")):
            self.assertEqual(text[text.index(start):text.index(end)],
                             old[old.index(start):old.index(end)])
        self.assertIn(repr(core.PARENT), text)
        self.assertIn("assert closed['binary_sha256'] == "+repr(core.CANDIDATE), text)
        self.assertIn('fp_wide_context_equality_assertion=True', text)

    def test_full_fp_fault_replay_plan_unchanged(self):
        old, new = regressions.original.read_text(), regressions.derive()
        functions = lambda text: {n.name: n for n in ast.parse(text).body
                                  if isinstance(n, ast.FunctionDef)}
        self.assertEqual(ast.dump(functions(old)['plan']), ast.dump(functions(new)['plan']))
        for key in ('commands=plan(parent,candidate,root)', 'result.update(pins_unchanged='):
            self.assertEqual(old.split(key)[1], new.split(key)[1])


if __name__ == '__main__':
    unittest.main()
