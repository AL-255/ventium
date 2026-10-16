import os
from pathlib import Path
import unittest

import prepare_next_ready_cofactor as recipe
import run_next_ready_cofactor_leaf as leaf
import run_next_ready_cofactor_cache as cache
import build_next_ready_core as build


class NextReadyTests(unittest.TestCase):
    def test_exact_parent_and_no_reapplication(self):
        source=Path(os.environ['NEXT_READY_PARENT']).read_text()
        changed=recipe.transform(source)
        self.assertIn('assign c_next_ready = c_next_req &&',changed)
        self.assertIn('(mc_prime_slot || (mc_old_slot && cacheable))',changed)
        self.assertIn('&& (|tag_prime_hit) &&',changed)
        self.assertIn('assert (c_next_ready === c_next_ready_before_cofactor)',changed)
        self.assertEqual(source.count(recipe.END),changed.count(recipe.END))
        for bad in (source+'\n',changed):
            with self.assertRaises(AssertionError):recipe.transform(bad)

    def test_symbolic_and_simulation_negative_controls(self):
        problem,results=leaf.symbolic()
        self.assertEqual(results,['unsat','sat','sat','sat','sat'])
        self.assertEqual(problem.count('(check-sat)'),5)
        source=Path(os.environ['NEXT_READY_PARENT']).read_text()
        positive=leaf.fixture(source,'positive')
        self.assertIn('k<65536',positive)
        for name in leaf.MUTANTS:self.assertNotEqual(positive,leaf.fixture(source,name))

    def test_current_interface_and_full_array_miter(self):
        pp=Path(os.environ['NEXT_READY_PREPROCESS']).read_text()
        for flat in (False,True):
            tb=cache.fixture(cache.previous.original.ports(pp),flat)
            self.assertNotIn('PAIR_CURRENT_U_ONLY',tb)
            self.assertNotIn('contract_pair_valid',tb)
            self.assertIn('run_next_ready_underfill();',tb)
            self.assertIn('CUT_EQUIV c_next_ready',tb)
            self.assertIn('NEXT-READY-ARRAY data',tb)

    def test_builder_retains_private_host_and_profile_guards(self):
        text=build.adapted_main()
        self.assertIn("'tb_next_ready_'",text)
        self.assertIn("(leaf/'ven_l1d.sv')",text)
        self.assertIn('len(files) == 195',text)
        self.assertIn('== 153',text)
        self.assertIn('pass_fds=(9,)',text)
        self.assertIn('return native.build(root)',text)


if __name__=='__main__':unittest.main()
