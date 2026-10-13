"""Admission tests; do not compile a model or start Vivado."""
import argparse
import copy
import json
from pathlib import Path
import unittest

import build_combined_core as build


class Admission(unittest.TestCase):
    prepared = {}

    def test_exact_preparation(self):
        build.validate(self.prepared)
        self.assertEqual(build.composition.sha(build.native.__file__), build.NATIVE_SHA)

    def test_reject_wrong_model_or_scope(self):
        for field, value in (
                ('parent_model', build.composition.MODELS['ancestor']),
                ('changes', []), ('ancestor_changes', []), ('exact_disjoint_composition', False)):
            wrong = copy.deepcopy(self.prepared)
            wrong[field] = value
            with self.assertRaises(AssertionError):
                build.validate(wrong)

    def test_reject_inherited_acceptance(self):
        for field in ('compiler_started', 'canonical_gate_passed', 'standard_suite',
                      'hardware_acceptance', 'parent_fault_differential_gate_passed'):
            wrong = dict(self.prepared, **{field: True})
            with self.assertRaises(AssertionError):
                build.validate(wrong)

    def test_reject_changed_jobs(self):
        wrong = dict(self.prepared, command=[s for s in self.prepared['command'] if s != 'VL_J=32'])
        with self.assertRaises(AssertionError):
            build.validate(wrong)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', type=Path, required=True)
    args = parser.parse_args()
    Admission.prepared = json.loads(args.prepared.read_text())
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Admission))
    raise SystemExit(not result.wasSuccessful())
