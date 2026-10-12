"""Host scope tests for the native eight-corpus plan."""
import ast
import unittest
from unittest.mock import patch

import run_intent_ready_core as driver


class IntentReadyCoreRegressions(unittest.TestCase):
    def test_exact_model_admission_and_unchanged_plan(self):
        text=driver.derive()
        original=(driver.HERE/'run_pair_intent_core.py').read_text()
        start,end='    common = ',"    assert stable(pins)"
        self.assertEqual(text[text.index(start):text.index(end)],
                         original[original.index(start):original.index(end)])
        self.assertIn(repr(driver.PARENT),text)
        self.assertIn("assert closed['binary_sha256'] == "+repr(driver.CANDIDATE),text)
        self.assertEqual(ast.get_docstring(ast.parse(text),clean=False),driver.__doc__)

    def test_native_comparisons_and_coverage_unchanged(self):
        text=driver.derive()
        original=(driver.HERE/'run_pair_intent_core.py').read_text()
        start,end='    try:',"if __name__ == '__main__':"
        self.assertEqual(text[text.index(start):text.index(end)],
                         original[original.index(start):original.index(end)])
        for marker in ('pass_fds=(9,)','intent_qualified_readiness_assertion=True',
                       "['pgrep','-x','vivado']","result['probe_runs'] == 4240",
                       'canonical_gate_passed=False','hardware_acceptance=False'):
            self.assertIn(marker,text)

    def test_reject_lifecycle_drift(self):
        with patch.object(driver,'BASE_SHA','0'*64):
            with self.assertRaisesRegex(ValueError,'core regression lifecycle drift'):
                driver.derive()


if __name__=='__main__':unittest.main()
