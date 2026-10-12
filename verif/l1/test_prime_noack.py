"""Source/guard contract tests, not processor or timing qualification."""
import copy
import os
from pathlib import Path
import unittest

import prepare_prime_noack as recipe
from build_prime_noack_core import check_leaf
from run_prime_noack_leaf import equations
from run_prime_noack_system import adapt, FE


class Tests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['PRIME_NOACK_PARENT'])
        self.inputs = {name: (root/name).read_text() for name in recipe.HASHES}

    def test_exact_inputs_and_guard_delta(self):
        changed = recipe.transform(self.inputs)
        core = changed['rtl/core/core.sv']
        old = recipe.statement(self.inputs['rtl/core/core.sv'], 'pipe_fp_live_arm')
        self.assertEqual(recipe.statement(core, 'pipe_fp_live_arm'), old)
        new = recipe.statement(core, 'pipe_prime_live_arm')
        restored = new.replace('pipe_prime_live_arm', 'pipe_fp_live_arm').replace(
            '(pipe_agi || fp_sys_bail);', '!pipe_mem_wait;')
        self.assertEqual(restored, old)
        self.assertNotIn('!u_d.is_mem', new)
        self.assertIn('!pipe_mem_active_q', new)

    def test_every_consumer_guard_retained(self):
        changed = recipe.transform(self.inputs)
        for kind, leaf in [('agi', 'core_agi_resident_prime.svh'), ('ref', 'core_ref_operand_prime.svh')]:
            path = 'rtl/core/'+leaf
            old = recipe.statement(self.inputs[path], kind+'_prime_commit', starts=kind+'_prime_offer')
            new = recipe.statement(changed[path], kind+'_prime_commit', starts=kind+'_prime_offer')
            self.assertEqual(new.replace('pipe_prime_live_arm', 'pipe_fp_live_arm'), old)
            self.assertIn('assert ('+kind+'_prime_commit === '+kind+'_prime_before_ack_cut)', changed[path])

    def test_drift_missing_file_and_reapplication_rejected(self):
        for name in recipe.HASHES:
            changed = dict(self.inputs); changed[name] += '\n'
            with self.assertRaises(ValueError): recipe.transform(changed)
        with self.assertRaises(ValueError): recipe.transform({})
        with self.assertRaises(ValueError): recipe.transform(recipe.transform(self.inputs))

    def test_native_admission_requires_all_witnesses(self):
        good = dict(passed=True, pins_unchanged=True, errors=[], build_exit=0,
                    rows=[dict(mutant=0, native_exit=0, counts=dict(samples=6_103_040,
                        fp=1, agi=1, ref_int=1, ref_fp=1, noack=1, held=1, blocked=1))]+
                         [dict(mutant=i, native_exit=-6) for i in (1, 2, 3)])
        check_leaf(good)
        for key in good['rows'][0]['counts']:
            bad = copy.deepcopy(good); bad['rows'][0]['counts'][key] = 0
            with self.assertRaises(AssertionError): check_leaf(bad)
        for i in (1, 2, 3):
            bad = copy.deepcopy(good); bad['rows'][i]['native_exit'] = 0
            with self.assertRaises(AssertionError): check_leaf(bad)
        for key in ('passed', 'pins_unchanged'):
            bad = copy.deepcopy(good); bad[key] = False
            with self.assertRaises(AssertionError): check_leaf(bad)

    def test_enabled_source_equations_extract(self):
        text = equations(self.inputs, recipe.transform(self.inputs))
        for name in ('reference_arm', 'raw_candidate_arm', 'reference_agi',
                     'candidate_agi', 'reference_ref', 'candidate_ref', 'pipe_mem_wait'):
            self.assertEqual(text.count('assign '+name+' ='), 1)
        self.assertIn('!pipe_agi', text)
        self.assertIn('!fp_sys_bail', text)

    def test_cold_adapters_keep_full_comparisons(self):
        source = (FE/'run-ref-operand-prime.py').read_text()
        for kind in ('agi', 'ref'):
            text = adapt(source, kind)
            self.assertIn("assert profiles['candidate']==profiles['control']", text)
            self.assertIn("assert a['state_sha256']==b['state_sha256']", text)
            self.assertIn("assert a['cycle_sha256']==b['cycle_sha256']", text)
            self.assertIn('assert compare_complete(gold,trace,log)==0', text)
            self.assertIn("assert a['resident_primes']==b['resident_primes']", text)
            self.assertIn('with golden_lock:', text)
            with self.assertRaises(ValueError): adapt(text, kind)


if __name__ == '__main__':
    unittest.main()
