"""Exact-source tests only; whole-core execution is required separately."""
import hashlib
import os
from pathlib import Path
import re
import unittest

import prepare_load_read_ack as recipe


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(os.environ['LOAD_READ_ACK_PARENT'])/recipe.PAYLOAD).read_text()
        if hashlib.sha256(cls.source.encode()).hexdigest() != recipe.PARENT:
            raise AssertionError('wrong test predecessor')

    def test_only_five_ack_identifiers_and_three_witnesses_change(self):
        changed = recipe.transform(self.source)
        for state in ('S_LOAD', 'S_LOAD2', 'S_FLOAD'):
            self.assertEqual(changed.count(recipe.witness(state)), 1)
            changed = changed.replace(recipe.witness(state), '')
        self.assertEqual(len(re.findall(r'\bmem_read_ack\b', changed)), 5)
        self.assertEqual(changed.replace('mem_read_ack', 'mem_ack'), self.source)

    def test_drift_and_reapplication_rejected(self):
        for invalid in (self.source+'\n', self.source.replace('xp_cross', 'xp_pend'),
                        recipe.transform(self.source)):
            with self.assertRaises(ValueError): recipe.transform(invalid)

    def test_all_witnesses_require_read_owner_and_full_ack_equality(self):
        for state in ('S_LOAD', 'S_LOAD2', 'S_FLOAD'):
            code = recipe.witness(state)
            self.assertTrue(code.startswith('`ifndef SYNTHESIS\n'))
            self.assertTrue(code.endswith('`endif\n'))
            self.assertIn('!mem_we && (mem_read_ack === mem_ack)', code)
            self.assertIn('q_pc, xp_pend, xp_cross, q_callf_mem, q_jmpf_mem', code)


if __name__ == '__main__': unittest.main()
