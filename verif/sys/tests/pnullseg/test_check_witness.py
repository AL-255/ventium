#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only grader tests; synthetic tracefmt records are NOT DUT evidence."""
import copy
import json
from pathlib import Path
import unittest
import check_witness as gate


class WitnessTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((gate.HERE / "manifest.json").read_text())
        self.sym = dict(fault_ds_read=0xF1000, fault_ds_write=0xF1010,
                        fault_es_read=0xF1020, fault_es_write=0xF1030,
                        gp_handler=0xF1100, do_exit=0xF1200, do_out=0xF1204)
        self.log = "\n".join(
            f"[FAULT] vec=13 err=00000000 pc={pc:08x} state=3 v86=0 depth=1"
            for pc in list(self.sym.values())[:4])
        self.log += ("\ntb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) "
                     "after 9 retired in 200 clocks\n"
                     "tb: retired 9 instructions in 200 clocks (bus: 0 reads, 0 writes)\n")
        seg = {key: 0x10 for key in gate.tracefmt.SEG_KEYS}
        seg["cs"] = 8
        sysregs = dict(cr0=1, cr2=0, cr3=0, cr4=0)
        rows = []
        for case, pc in enumerate(list(self.sym.values())[:4]):
            current_seg = dict(seg, ds=0 if case < 2 else 0x10,
                               es=0x10 if case < 2 else 3)
            for point, esp in ((pc, 0x8FFF0), (self.sym["gp_handler"], 0x8FFD0)):
                rows.append(gate.tracefmt.func_record(len(rows), point, 0xCD7,
                    dict(gate.STAGE_GPRS, esp=esp), current_seg, sysregs=sysregs))
        terminal = {key: int(self.manifest["witnesses"].get(key, "0"), 16)
                    for key in gate.tracefmt.GPR_KEYS}
        rows.append(gate.tracefmt.func_record(len(rows), self.sym["do_out"], 2,
                                             terminal, seg, sysregs=sysregs))
        self.trace = gate.tracefmt.Trace(gate.tracefmt.header("rtl", "func", sys=True), rows)

    def grade(self, **changes):
        return gate.grade_records(changes.get("trace", self.trace),
                                  changes.get("log", self.log), self.sym,
                                  self.manifest, changes.get("return_code", 85))

    def test_positive(self):
        self.assertEqual(self.grade()["faults"], 4)
        self.assertEqual(self.grade()["fault_delivery_events"], 4)
        self.assertEqual(self.grade()["legacy_reported_retires"], 9)

    def test_profile_requires_actual_define(self):
        with self.assertRaises(ValueError):
            gate.compile_profile('C "--cc -Mdir obj_dir_dummy"')
        self.assertIn("+define+VEN_SEG_ENFORCE",
                      gate.compile_profile('C "--cc +define+VEN_SEG_ENFORCE -Mdir obj_dir_dummy"'))

    def test_wrong_error_code(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("err=00000000", "err=00000004", 1))

    def test_wrong_fault_pc(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("pc=000f1000", "pc=000f1001"))

    def test_extra_fault(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "[FAULT] vec=14 err=00000000 pc=000f1300\n")

    def test_truncated_fault(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log + "[FAULT] vec=13 err=")

    def test_wrong_terminal_gpr(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["edi"] = "0x00000001"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_return_code_and_closure(self):
        with self.assertRaises(ValueError):
            self.grade(return_code=0)
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("isa-debug-exit (out 0xf4)", "quiescent for400"))

    def test_non_contiguous_trace(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["n"] += 1
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_duplicate_delivery_marker(self):
        tr = copy.deepcopy(self.trace)
        tr.records[2]["pc"] = tr.records[0]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_missing_delivery_marker(self):
        tr = copy.deepcopy(self.trace)
        tr.records[0]["pc"] = gate.tracefmt.h32(0xF0900)
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_out_of_order_delivery_markers(self):
        tr = copy.deepcopy(self.trace)
        tr.records[0]["pc"], tr.records[2]["pc"] = tr.records[2]["pc"], tr.records[0]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_changed_fault_destination(self):
        for n, key in ((0, "eax"), (4, "ecx")):
            with self.subTest(record=n, destination=key):
                tr = copy.deepcopy(self.trace)
                tr.records[n][key] = "0xaabbccdd"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_changed_non_destination_gpr(self):
        tr = copy.deepcopy(self.trace)
        tr.records[3]["edi"] = "0x00000000"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_wrong_delivery_or_handler_flags(self):
        for n in (0, 1):
            with self.subTest(record=n):
                tr = copy.deepcopy(self.trace)
                tr.records[n]["eflags"] = "0x00000002"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_wrong_delivery_or_handler_esp(self):
        for n in (0, 1):
            with self.subTest(record=n):
                tr = copy.deepcopy(self.trace)
                tr.records[n]["esp"] = "0x00090000"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_wrong_null_selectors(self):
        for n, key in ((0, "ds"), (5, "es")):
            with self.subTest(record=n, selector=key):
                tr = copy.deepcopy(self.trace)
                tr.records[n][key] = "0x0010"
                with self.assertRaises(ValueError):
                    self.grade(trace=tr)

    def test_handler_must_be_adjacent(self):
        tr = copy.deepcopy(self.trace)
        tr.records[1]["pc"], tr.records[2]["pc"] = tr.records[2]["pc"], tr.records[1]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_no_extra_handler_entry(self):
        tr = copy.deepcopy(self.trace)
        tr.records[-1]["pc"] = gate.tracefmt.h32(self.sym["gp_handler"])
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_incomplete_trace(self):
        tr = copy.deepcopy(self.trace)
        del tr.records[-1]["eflags"]
        with self.assertRaises(ValueError):
            self.grade(trace=tr)

    def test_missing_footer(self):
        with self.assertRaises(ValueError):
            self.grade(log=self.log.replace("tb: retired 9", "tb: retired 8"))

    def test_out_of_range_nonterminal_field(self):
        tr = copy.deepcopy(self.trace)
        tr.records[0]["eax"] = "0x100000000"
        with self.assertRaises(ValueError):
            self.grade(trace=tr)


if __name__ == "__main__":
    unittest.main()
