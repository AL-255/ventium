"""Verify the complete native regression plan is preserved by the adapter."""
import ast
import unittest
from unittest.mock import patch

import run_payload_region_core as driver


class RegionCore(unittest.TestCase):
    def test_exact_identity_and_complete_plan(self):
        text=driver.derive(); original=(driver.HERE/'run_pair_intent_core.py').read_text()
        for start,end in (('    common = ', '    assert stable(pins)'),
                          ('    try:', "if __name__ == '__main__':")):
            self.assertEqual(text[text.index(start):text.index(end)],
                             original[original.index(start):original.index(end)])
        self.assertIn(repr(driver.PARENT),text)
        self.assertIn("assert closed['binary_sha256'] == "+repr(driver.CANDIDATE),text)
        self.assertEqual(ast.get_docstring(ast.parse(text),clean=False),driver.__doc__)

    def test_guards_coverage_and_scope_preserved(self):
        text=driver.derive()
        for marker in ('pass_fds=(9,)',"['pgrep','-x','vivado']",'payload_region_equality_assertion=True',
                       "result['probe_runs'] == 4240",'canonical_gate_passed=False',
                       'standard_suite=False','hardware_acceptance=False','gameplay_ipc=None'):
            self.assertIn(marker,text)

    def test_reject_lifecycle_drift(self):
        with patch.object(driver,'BASE_SHA','0'*64):
            with self.assertRaises(ValueError): driver.derive()


if __name__=='__main__': unittest.main()
