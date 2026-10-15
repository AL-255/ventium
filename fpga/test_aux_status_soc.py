"""Reject additional source changes and false AUX witness closure."""
import unittest
from copy import deepcopy
from pathlib import Path

import build_aux_status_soc as build


class Transfer(unittest.TestCase):
    def test_output_must_not_overlap_any_input_tree(self):
        parent = Path('/external/tmp/parent')
        proof = Path('/external/tmp/proof')
        build.check_destination(Path('/external/tmp/new-aux'), parent, proof)
        for root in (parent, parent/'source/new-aux', parent.parent, proof/'new-aux'):
            with self.assertRaises(AssertionError): build.check_destination(root, parent, proof)
        with self.assertRaises(AssertionError):
            build.check_destination(parent/'source/../new-aux', parent)

    def test_parent_profile_requires_exact_closed_pc_and_directed_model(self):
        for profile, (pc, core) in build.PROFILES.items():
            old = dict(directed_model=core)
            closed = dict(passed=True, native_exit=0, inputs_unchanged=True, binary_sha256=pc)
            self.assertEqual(build.check_parent(profile, old, closed, pc), (pc, core))
            for key, value in (('passed', False), ('native_exit', 1),
                               ('inputs_unchanged', False), ('binary_sha256', 'wrong')):
                bad = deepcopy(closed)
                bad[key] = value
                with self.assertRaises(AssertionError): build.check_parent(profile, old, bad, pc)
            with self.assertRaises(AssertionError): build.check_parent(profile, old, closed, 'wrong')
            with self.assertRaises(AssertionError):
                build.check_parent(profile, dict(directed_model='wrong'), closed, pc)
            other = next(name for name in build.PROFILES if name != profile)
            with self.assertRaises(AssertionError): build.check_parent(other, old, closed, pc)
            with self.assertRaises(AssertionError): build.check_parent('latest', old, closed, pc)

    def test_one_line_transfer_only(self):
        original = (build.REPO/build.FILE).read_bytes()
        fixed = build.recipe.transform(original.decode()).encode()
        self.assertTrue(build.check_delta(build.FILE, original, fixed))
        self.assertFalse(build.check_delta('rtl/core/core.sv', b'unchanged', b'unchanged'))
        for name, before, after in ((build.FILE, original, original),
                                     (build.FILE, original, fixed+b'\n'),
                                     ('rtl/core/core.sv', b'old', b'new')):
            with self.assertRaises(AssertionError): build.check_delta(name, before, after)

    def test_every_original_case_and_mutant_included(self):
        cases = build.evidence.expected_cases()
        self.assertEqual(len(cases), 996)
        self.assertEqual(sum(v == 1 for v, _, _ in cases), 496)
        self.assertEqual(sum(e == 'parent_bug' for _, _, e in cases), 240)
        self.assertEqual(sum(e == 'constant_aux_mutant' for _, _, e in cases), 4)
        self.assertEqual(len(set((v, c) for v, c, _ in cases)), len(cases))

    def test_false_completion_and_relabelled_failures_rejected(self):
        grade = build.evidence.grade
        positive = dict(expected='pass', exit=0, affinity=[13])
        failure = dict(expected='parent_bug', exit=1, affinity=[13])
        grade(positive, 'PS2-AUX-OK completed', 'pass')
        grade(failure, 'PS2-AUX-ORIGIN-MISMATCH', 'parent_bug')
        for row, text, expected in (
            (positive | {'exit': 1}, 'PS2-AUX-OK completed', 'pass'),
            (positive, 'PS2-AUX-OK PS2-AUX-ORIGIN-MISMATCH', 'pass'),
            (positive | {'affinity': [12]}, 'PS2-AUX-OK completed', 'pass'),
            (failure | {'exit': 0}, 'PS2-AUX-ORIGIN-MISMATCH', 'parent_bug'),
            (failure, 'PS2-AUX-OK PS2-AUX-ORIGIN-MISMATCH', 'parent_bug'),
            (failure, 'unrelated failure', 'parent_bug'),
            (failure, 'PS2-AUX-ORIGIN-MISMATCH', 'constant_aux_mutant'),
        ):
            with self.assertRaises(AssertionError): grade(row, text, expected)


if __name__ == '__main__': unittest.main()
