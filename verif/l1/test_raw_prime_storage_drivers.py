import ast
import unittest

import run_raw_prime_storage_core as core
import run_raw_prime_storage_func as func
import audit_raw_prime_storage_func as audit
import audit_raw_prime_storage_core as core_audit


class Drivers(unittest.TestCase):
    def test_corpora_and_original_thresholds_unchanged(self):
        text = core.derive(); ast.parse(text)
        for token in ("('load-store'", "('held'", "('branch'", "('integer'", "('fp'",
                      "('agi'", "('ref'", "('agi-store'", 'pass_fds=(9,)',
                      "result['probe_runs'] == 4240", 'clocks=21190336',
                      'prime=282808', 'shape_only=1536', core.CANDIDATE,
                      "started['definitions'] == parent_start['definitions']"):
            self.assertIn(token, text)

    def test_qualified_reference_policy_and_new_identity(self):
        ast.parse(func.derive()); text=audit.derive(); ast.parse(text)
        for token in ('run_raw_prime_storage_func', 'raw-prime-storage-func-r1',
                      'raw-prime-storage-core-r1', 'ventium-raw-prime-storage-func-oct16-r1.service'):
            self.assertIn(token, text)
        self.assertEqual(func.PARENT, core.PARENT)
        self.assertEqual(func.MODEL, core.CANDIDATE)
        self.assertEqual(func.REFERENCE, '998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85')

    def test_complete_audit_and_original_failure_preserved(self):
        text = core_audit.derive(); ast.parse(text)
        for token in ("not done['passed']", "len(done['errors'])==1", 'compare_pair(old,new)',
                      'counts=probe_pair(*texts)', 'legacy_aggregate_gate_passed=False',
                      'canonical_gate_passed=False', 'same_input_equivalence=True',
                      'febd335ce935488f8ae109377d4f86c7', '1bb8eb4df8ed4070b282ad380fe6c64b'):
            self.assertIn(token, text)


if __name__ == '__main__':unittest.main()
