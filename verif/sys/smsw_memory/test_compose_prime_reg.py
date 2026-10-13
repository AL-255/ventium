"""Test composition/drift rejection; these are not combined RTL simulations."""
import argparse
from pathlib import Path
import unittest

import compose_prime_reg as recipe


class Composition(unittest.TestCase):
    inputs = {}

    def test_exact_commuting_union(self):
        ancestor, flags, smsw = (self.inputs[k] for k in ('ancestor', 'flags', 'smsw'))
        combined = recipe.combine(ancestor, flags, smsw)
        self.assertEqual({p for p in ancestor if ancestor[p] != combined[p]},
                         {recipe.FLAG_PATH, *recipe.SMSW_PATHS})
        self.assertEqual(combined[recipe.FLAG_PATH], flags[recipe.FLAG_PATH])
        for p in recipe.SMSW_PATHS:
            self.assertEqual(combined[p], smsw[p])

    def test_reject_missing_or_extra_source(self):
        for action in ('remove', 'add'):
            inputs = {k: dict(v) for k, v in self.inputs.items()}
            if action == 'remove':
                inputs['smsw'].pop(recipe.FLAG_PATH)
            else:
                inputs['flags']['rtl/unexpected.sv'] = b''
            with self.assertRaises(ValueError):
                recipe.combine(*inputs.values())

    def test_reject_unrelated_or_overlap_edit(self):
        for key, path in (('flags', recipe.SMSW_PATHS[0]),
                          ('smsw', recipe.FLAG_PATH), ('smsw', 'rtl/core/u_pipe.sv')):
            inputs = {k: dict(v) for k, v in self.inputs.items()}
            inputs[key][path] += b'\n'
            with self.assertRaises(ValueError):
                recipe.combine(*inputs.values())

    def test_reject_edited_recipe_output(self):
        for key, path in (('flags', recipe.FLAG_PATH), ('smsw', recipe.SMSW_PATHS[0])):
            inputs = {k: dict(v) for k, v in self.inputs.items()}
            inputs[key][path] += b'\n'
            with self.assertRaises(ValueError):
                recipe.combine(*inputs.values())

    def test_reject_drifted_common_parent(self):
        inputs = {k: dict(v) for k, v in self.inputs.items()}
        for source in inputs.values():
            source['rtl/core/u_pipe.sv'] += b'\n'
        with self.assertRaises(ValueError):
            recipe.combine(*inputs.values())

    def test_corner_audit_does_not_convert_known_failures_to_passes(self):
        audit = dict(audit_passed=True, differential_cases=85, intel_spec_only_cases=20,
                     complete_fault_differential_gate_passed=False,
                     standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
        recipe.check_audit('smsw-corners-audit-r1.json', audit)
        for field in ('complete_fault_differential_gate_passed', 'standard_suite', 'hardware_acceptance'):
            with self.assertRaises(AssertionError):
                recipe.check_audit('smsw-corners-audit-r1.json', dict(audit, **{field: True}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    for label, folder in (('ancestor', 'prime-cs-core-r1'),
                          ('flags', 'prime-reg-core-r1'), ('smsw', 'smsw-core-r1')):
        root = args.evidence/folder/'candidate'
        Composition.inputs[label] = {str(p.relative_to(root)): p.read_bytes()
                                     for p in root.rglob('*') if p.is_file()}
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Composition))
    raise SystemExit(not result.wasSuccessful())
