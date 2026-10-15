"""Host checks for the private pair/next cofactor and unfiltered fixture."""
import ast
import itertools
from pathlib import Path
import unittest

import prepare_pair_next_disjoint as recipe
import run_pair_next_disjoint as driver

PARENT = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/prefix-payload-core-r1/candidate')


class Recipe(unittest.TestCase):
    def test_parent_identity_and_reapplication(self):
        for name in recipe.PARENTS:
            source = (PARENT/name).read_text()
            changed = recipe.transform(source,name)
            self.assertNotEqual(source,changed)
            for bad in (source+'\n',changed):
                with self.assertRaises(ValueError): recipe.transform(bad,name)

    def test_original_assertion_and_idle_admission_remain(self):
        new = recipe.transform((PARENT/'rtl/mem/ven_l1d.sv').read_text(),'rtl/mem/ven_l1d.sv')
        self.assertIn("parameter bit PAIR_NEXT_DISJOINT = 1'b0",new)
        self.assertIn('assert (pair_lookup_active === pair_lookup_before_ack_cut)',new)
        self.assertIn('assert (!mc_lookup_next)',new)
        self.assertIn('((!c_req && !rd_armed) && (PAIR_NEXT_DISJOINT || !mc_lookup_next))',new)
        self.assertNotIn('PAIR_CURRENT_U_ONLY',new)

    def test_boolean_cofactor_and_conflict_witness(self):
        conflicts = 0
        for request,common,idle,owned,capture,prime,store,nxt in itertools.product((False,True),repeat=8):
            old = request and common and ((idle or owned) and not nxt or capture or prime or store)
            new = request and common and (idle or owned or capture or prime or store)
            if not (request and nxt): self.assertEqual(old,new)
            elif old != new: conflicts += 1
        self.assertGreater(conflicts,0)

    def test_derived_fixture_has_no_input_filter(self):
        text = driver.leaf_driver()
        ast.parse(text); ast.parse(driver.core_driver())
        module = {'__name__':'fixture_test','__file__':str(driver.__file__)}
        exec(compile(text,'<derived-leaf>','exec'),module)
        bench = module['fixture']([('input','[1:0] ','pair_req_valid')],True)
        self.assertIn('.pair_req_valid(pair_req_valid)',bench)
        self.assertNotIn('.pair_req_valid(contract_pair_valid)',bench)
        self.assertIn("if (c_req || pair_req_ready != 2'd2)",bench)
        self.assertEqual(bench.count('    #1;\n    if (c_req || pair_req_ready'),1)
        self.assertIn('committed<0',bench)
        generic = module['fixture']([],False)
        self.assertIn('committed<2',generic)


if __name__ == '__main__': unittest.main()
