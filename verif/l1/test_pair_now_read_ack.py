"""Exact-source tests; these do not replace whole-core behavioral checks."""
import hashlib
import os
from pathlib import Path
import unittest

import prepare_pair_now_read_ack as recipe


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(os.environ['PAIR_NOW_READ_ACK_PARENT'])/recipe.PAYLOAD).read_text()
        if hashlib.sha256(cls.source.encode()).hexdigest() != recipe.PARENT:
            raise AssertionError('wrong immediate-pair predecessor')

    def test_only_one_consumer_and_witness_change(self):
        changed = recipe.transform(self.source)
        self.assertEqual(changed.count(recipe.NEW+recipe.WITNESS), 1)
        self.assertEqual(changed.replace(recipe.NEW+recipe.WITNESS,recipe.OLD), self.source)
        self.assertEqual(recipe.NEW,recipe.OLD.replace('mem_ack','mem_read_ack'))

    def test_drift_and_reapplication_rejected(self):
        for invalid in (self.source+'\n',recipe.transform(self.source)):
            with self.assertRaises(ValueError): recipe.transform(invalid)

    def test_witness_keeps_full_acceptance_and_read_ownership(self):
        self.assertTrue(recipe.WITNESS.startswith('`ifndef SYNTHESIS\n'))
        self.assertTrue(recipe.WITNESS.endswith('`endif\n'))
        self.assertIn('pipe_v_pair_now_accept === pair_now_before_read_ack',recipe.WITNESS)
        self.assertIn('!mem_we && (mem_read_ack === mem_ack)',recipe.WITNESS)


if __name__ == '__main__': unittest.main()
