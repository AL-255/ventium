#!/usr/bin/env python3
"""Tiny host-only regressions for system-gate fault evidence parsing."""

from collections import Counter
import unittest

from check_faultlog import check_counts, read_counts


PF = "[FAULT] vec=14 err=00000002 pc=000f045d state=40 v86=0 depth=0\n"
GP = "[FAULT] vec=13 err=00000060 pc=000f045d state=40 v86=0 depth=0\n"
DBG = "tb: FLT vec=14 fault_pc=000f045d cs=0008 err=00000002 cr2=00080012\n"


class FaultLogTests(unittest.TestCase):
    def test_debug_observer_is_not_a_second_fault(self):
        counts = read_counts([PF, DBG, PF, DBG, "[FRMPG] nslots=5\n"])
        check_counts(counts, {(14, 2): 2})

    def test_real_duplicate_is_not_deduplicated(self):
        with self.assertRaises(ValueError):
            check_counts(read_counts([PF, PF]), {(14, 2): 1})

    def test_missing_event_fails(self):
        with self.assertRaises(ValueError):
            check_counts(read_counts([DBG]), {(14, 2): 1})

    def test_wrong_vector_with_right_error_fails(self):
        with self.assertRaises(ValueError):
            check_counts(read_counts([PF.replace("vec=14", "vec=13")]), {(14, 2): 1})

    def test_unexpected_class_and_escalation_fail(self):
        for record in [GP, PF.replace("err=00000002", "err=00000006"),
                       PF.replace("vec=14", "vec=8")]:
            with self.subTest(record=record), self.assertRaises(ValueError):
                check_counts(read_counts([PF, record]), {(14, 2): 1})

    def test_pxwrap_allows_only_documented_extra_gp_zero(self):
        gp0 = GP.replace("err=00000060", "err=00000000")
        check_counts(read_counts([PF, GP, gp0]), {(14, 2): 1, (13, 0x60): 1}, {(13, 0)})
        with self.assertRaises(ValueError):
            check_counts(read_counts([PF, GP, gp0.replace("vec=13", "vec=14")]),
                         {(14, 2): 1, (13, 0x60): 1}, {(13, 0)})

    def test_spliced_truncated_and_merged_stderr_fail_closed(self):
        for record in ["tb: " + PF, PF.replace("err=", "tb: diagnostic\nerr="),
                       PF.replace("pc=000f045d ", ""), PF + "garbage",
                       "tb: [FAULT] vec=0x0e fault_pc=000f045d\n"]:
            with self.subTest(record=record), self.assertRaises(ValueError):
                read_counts([record])

    def test_canonical_count_shape(self):
        self.assertEqual(read_counts([PF, GP]), Counter({(14, 2): 1, (13, 0x60): 1}))


if __name__ == "__main__":
    unittest.main()
