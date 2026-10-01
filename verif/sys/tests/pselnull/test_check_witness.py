#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only closed-grader tests; synthetic records are NOT DUT evidence."""
import copy
import unittest
import check_witness as gate


class WitnessTests(unittest.TestCase):
    def setUp(self):
        self.sym = dict(fault_c=0xF031F, fault_d=0xF0345,
                        null_load_a=0xF0424, task_e=0xF0460,
                        exit_port=0xF04CE, exit_out=0xF04D2)
        self.log = (
            "[FAULT] vec=13 err=00000004 pc=000f031f state=3 v86=0 depth=1\n"
            "[FAULT] vec=10 err=00000004 pc=000f0345 state=3 v86=0 depth=1\n"
            "tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 6 retired in 500 clocks\n"
            "tb: retired 6 instructions in 500 clocks (bus: 20 reads, 10 writes)\n")
        gpr = {key: gate.WITNESSES.get(key, 0) for key in gate.tracefmt.GPR_KEYS}
        gpr["edx"] = 0xF4
        seg = {key: gate.WITNESSES[key] for key in gate.tracefmt.SEG_KEYS}
        regs = dict(cr0=0x80000001, cr2=0, cr3=0x11000, cr4=0)
        rows = []
        cases = [(0x500, dict(seg, cs=4)),
                 (self.sym["fault_c"], seg), (self.sym["fault_d"], seg),
                 (self.sym["null_load_a"], dict(seg, ds=0)),
                 (self.sym["task_e"], dict(seg, ds=0)),
                 (self.sym["exit_out"], seg)]
        for n, (pc, selectors) in enumerate(cases):
            rows.append(gate.tracefmt.func_record(n, pc, 2, gpr, selectors,
                                                sysregs=regs))
        self.trace = gate.tracefmt.Trace(gate.tracefmt.header("rtl", "func", sys=True), rows)

    def grade(self, **changes):
        return gate.grade_records(changes.get("trace", self.trace),
                                  changes.get("log", self.log), self.sym,
                                  changes.get("return_code", 133))

    def test_positive(self):
        self.assertEqual(self.grade()["cases"], ["B", "C", "D", "A", "E"])

    def test_wrong_reaped_status(self):
        for rc in (0, 85, 124, 137, -15):
            with self.subTest(return_code=rc), self.assertRaises(ValueError):
                self.grade(return_code=rc)

    def test_quiescence_not_debug_exit(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("WIN95 co-sim isa-debug-exit (out 0xf4)", "quiescent for400"))

    def test_wrong_stop_count(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("after 6 retired", "after 5 retired"))

    def test_duplicate_stop(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "tb: stop: quiescent for400\n")

    def test_missing_footer(self):
        with self.assertRaises(ValueError):
            self.grade(log="\n".join(self.log.splitlines()[:-1]))

    def test_wrong_footer_clock(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("instructions in 500", "instructions in 501"))

    def test_truncated_footer(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("20 reads, 10 writes)", "20 reads,"))

    def test_extra_page_fault(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "[FAULT] vec=14 err=00000000 pc=000f0500\n")

    def test_fault_order(self):
        lines = self.log.splitlines()
        lines[0], lines[1] = lines[1], lines[0]
        with self.assertRaises(ValueError):
            self.grade(log="\n".join(lines))

    def test_wrong_fault_error_and_pc(self):
        for old, new in (("err=00000004", "err=00000000"),
                         ("pc=000f031f", "pc=000f0320")):
            with self.subTest(field=old), self.assertRaises(ValueError):
                self.grade(log=self.log.replace(old, new, 1))

    def test_malformed_fault(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "[FAULT] vec=13 err=")

    def test_no_case_b(self):
        tr = copy.deepcopy(self.trace)
        tr.records[0]["cs"] = "0x0008"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_null_visible_checks(self):
        for n in (3, 4):
            with self.subTest(record=n):
                tr = copy.deepcopy(self.trace)
                tr.records[n]["ds"] = "0x0010"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_legacy_null_ds_exit_rejected(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["ds"] = "0x0000"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_unchanged_five_witnesses(self):
        for key in ("edi", "esi", "ebp", "ebx", "ecx"):
            with self.subTest(key=key):
                tr = copy.deepcopy(self.trace)
                tr.records[-1][key] = "0x00000000"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_qemu_postcommit_busy_witness_rejected(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["ebx"] = "0x00008b89"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_stop_before_out_rejected(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["pc"] = "0x000f04c8"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_noncontiguous_incomplete_out_of_range(self):
        for kind in ("n", "missing", "width"):
            with self.subTest(kind=kind):
                tr = copy.deepcopy(self.trace)
                if kind == "n": tr.records[2]["n"] = 9
                elif kind == "missing": del tr.records[2]["eflags"]
                else: tr.records[2]["eax"] = "0x100000000"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_capped_trace(self):
        tr = copy.deepcopy(self.trace)
        tr.records = tr.records * 200
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_fatal_log(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "%Error Assertion failed\n")


if __name__ == "__main__":
    unittest.main()
