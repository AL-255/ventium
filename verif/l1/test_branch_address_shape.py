import os
from pathlib import Path
import unittest

import prepare_branch_address_shape as recipe
import run_branch_address_shape as runner


class Shape(unittest.TestCase):
    def test_reversible_payload_only(self):
        source=Path(os.environ['BRANCH_ADDRESS_SOURCE'])
        original=(source/'core_mem_chain.svh').read_text(); changed=recipe.transform(original)
        self.assertEqual(changed.replace(recipe.PAYLOAD_NEW,recipe.PAYLOAD)
                         .replace(recipe.ASSERTION_NEW,recipe.ASSERTION),original)
        for text in (changed,original+'\n'):
            with self.assertRaises(ValueError): recipe.transform(text)
        for signal in ('mem_next_req','mem_next_commit','mc_prime_offer','mc_offer'):
            self.assertEqual(runner.assignment(original,signal),runner.assignment(changed,signal))

    def test_mutants_change_only_payload(self):
        source=Path(os.environ['BRANCH_ADDRESS_SOURCE']); positive=runner.fixture(source)
        for mutant in ('drop-held','drop-fp','never-branch','always-branch'):
            candidate=runner.fixture(source,mutant)
            self.assertNotEqual(candidate,positive)
            self.assertEqual(runner.raw_descriptor(candidate),runner.raw_descriptor(positive))


if __name__=='__main__':unittest.main()
