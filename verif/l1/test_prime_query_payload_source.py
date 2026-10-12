"""Exact scope and fail-closed tests; native miter/proof are separate."""
import os
from pathlib import Path
import unittest

import prepare_prime_query_payload as recipe
import test_prime_query_payload as native


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PRIME_QUERY_PARENT'])/'rtl/core'
        cls.inputs = {name:(cls.root/name).read_text() for name in native.HASHES}
        cls.source = cls.inputs['core_mem_chain.svh']

    def test_only_two_selectors_and_simulation_witness_change(self):
        changed = recipe.transform(self.source)
        for name in ('mem_next_addr', 'mem_next_wstrb'):
            new = recipe.assignment(changed, name)
            old = recipe.assignment(self.source, name)
            self.assertEqual(new.replace('!mc_valid_q', 'mc_prime_offer'), old)
            changed = changed.replace(new, old)
        changed = changed.replace(recipe.witness(self.source), '')
        start = changed.index('  // OFFER still owns admission.')
        end = changed.index('  assign mem_next_addr =', start)
        changed = changed[:start]+changed[end:]
        self.assertEqual(changed, self.source)

    def test_drift_and_reapplication_rejected(self):
        for invalid in (self.source+'\n', recipe.transform(self.source),
                        self.source.replace('mc_prime_offer', 'mc_offer')):
            with self.assertRaises(ValueError): recipe.transform(invalid)

    def test_witness_requires_request_payload_and_commit_ownership(self):
        witness = recipe.witness(self.source)
        self.assertTrue(witness.startswith('`ifndef SYNTHESIS\n'))
        self.assertTrue(witness.endswith('`endif\n'))
        self.assertIn('!mem_next_commit || mem_next_req', witness)
        self.assertIn('if (mem_next_req)', witness)
        self.assertIn('{mem_next_addr,mem_next_wstrb} ===', witness)

    def test_native_fixture_uses_both_real_payload_equations(self):
        sv = native.fixture(self.inputs)
        changed = recipe.transform(self.source)
        for name,suffix in (('mem_next_addr','addr'),('mem_next_wstrb','strb')):
            self.assertIn(recipe.assignment(self.source,name).replace(name+' =','old_'+suffix+' ='),sv)
            self.assertIn(recipe.assignment(changed,name).replace(name+' =','new_'+suffix+' ='),sv)
        self.assertIn('idle_differences++',sv)


if __name__ == '__main__': unittest.main()
