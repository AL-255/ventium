"""Guarded recipe checks; native descriptor/AGU comparison remains separate."""
import os
from pathlib import Path
import unittest
from prepare_mc_address_payload import OLD, NEW, ASSERTION, transform, raw_descriptor, assignment


class AddressPayloadRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['MC_ADDRESS_PARENT']).read_text()

    def test_only_payload_and_assertion(self):
        changed = transform(self.source)
        self.assertEqual(changed.replace(NEW+ASSERTION, OLD), self.source)
        self.assertEqual(raw_descriptor(changed), raw_descriptor(self.source))

    def test_source_drift_rejected(self):
        for source in (self.source+'\n', transform(self.source)):
            with self.assertRaises(ValueError): transform(source)

    def test_offer_commit_address_selection_unchanged(self):
        changed = transform(self.source)
        for name in ('mem_next_req','mem_next_commit','mem_next_addr','mem_next_wstrb',
                     'mc_prime_offer','mc_offer','mc_prime_accept','mc_chain_accept'):
            self.assertEqual(assignment(changed,name),assignment(self.source,name),name)

    def test_reference_and_agi_priority_preserved(self):
        changed = transform(self.source)
        for name in ('mc_query_seg','mc_query_ea'):
            expr = assignment(changed,name)
            self.assertIn('agi_prime_select ?',expr)
            self.assertIn(': ref_prime_select ?',expr)
        self.assertIn('assign mc_address_payload = mc_query_u;',changed)


if __name__ == '__main__': unittest.main()
