"""Reject additional source changes and false AUX witness closure."""
import unittest

import build_aux_status_soc as build


class Transfer(unittest.TestCase):
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
