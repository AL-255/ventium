#!/usr/bin/env python3
"""Small fail-closed tests; do not run a compiler or admit a cache candidate."""
import copy
import unittest

from build_pair_now_core import check_rows


class Admission(unittest.TestCase):
    def setUp(self):
        self.rows = [dict(label=label, mutant=mutant, build_exit=0,
                          native_exit=1 if mutant else 0, checks=12, returns=4, held=3)
                     for label, mutant in (('ff-primary', False),
                         ('lut-primary-shadow', False), ('wrong-unowned', True))]

    def test_complete_native_rows(self):
        check_rows(self.rows)

    def test_incomplete_or_failed_rows(self):
        mutations = [(0, 'build_exit', 1), (0, 'native_exit', 1),
                     (1, 'native_exit', 1), (2, 'native_exit', 0),
                     (0, 'checks', 0), (1, 'returns', 0), (1, 'held', 0),
                     (2, 'label', 'other-mutant'), (2, 'mutant', False)]
        for row, field, value in mutations:
            with self.subTest(row=row, field=field):
                changed = copy.deepcopy(self.rows)
                changed[row][field] = value
                with self.assertRaises(AssertionError):
                    check_rows(changed)

    def test_missing_mutant_or_layout(self):
        for index in range(3):
            with self.subTest(missing=index), self.assertRaises(AssertionError):
                check_rows(self.rows[:index] + self.rows[index+1:])


if __name__ == '__main__':
    unittest.main()
