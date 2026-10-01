#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Synthetic host contracts only; never DUT/QEMU correctness evidence."""
import copy
import unittest

import check_witness as gate
import run_gate


def synthetic(case, producer="rtl"):
    info = gate.variant(case)
    sym = dict(info, pm32_entry=0xF0900, tested_op=0xF1000, tested_end=0xF1003,
               db_handler=0xF1100, capture_ip=0xF1110, capture_cs=0xF1120,
               capture_flags=0xF1130, capture_dr6=0xF1140, tested_iret=0xF1200,
               do_exit=0xF14F0, set_exit_port=0xF14FC, do_out=0xF1500, fail=0xF1600)
    sym["expected_frame_ip"] = sym["tested_end"]
    image = bytearray(65536)
    image[0x1000:0x1003] = b"\x66\x8f\x03" if case == 2 else b"\x8f\x45\x00" if case == 3 else b"\x64\x8f\x03"
    image[0x1200] = 0xCF
    image[0x14FC:0x1501] = b"\x66\xba\xf4\x00\xee"
    gpr = dict(eax=0x42, ebx=case, ecx=info["captured_esp"], esp=0x7000,
               ebp=info["expected_handlers"], esi=info["expected_dr6"],
               edi=0 if case == 4 else sym["tested_end"], edx=0xF4)
    seg = dict(cs=8, ss=0x10, ds=0x20 if case == 2 else 0x10, es=0x10, fs=0x18, gs=0x10)
    sysregs = dict(cr0=1, cr2=0, cr3=0, cr4=0)
    labels = ["pm32_entry", "tested_op"]
    if case != 4:
        labels += ["delivery_marker", "db_handler", "capture_ip", "capture_cs", "capture_flags", "capture_dr6", "tested_iret"]
    labels += ["tested_end", "set_exit_port"]
    rows = []
    for n, label in enumerate(labels):
        regs = dict(gpr)
        if n == 0:
            regs.update(esp=0x7000 - info["operand_width"], ebx=0x4000, ebp=0x4000, ecx=0)
        elif case != 4 and label not in ("tested_iret", "tested_end", "set_exit_port"):
            regs["esp"] = 0x6FF4
        if label in ("tested_op", "delivery_marker"):
            regs["ecx"] = 0
        if label == "capture_cs":
            regs["edx"] = 8
        if label == "capture_flags":
            regs["ebp"] = 2
        pc = sym["db_handler"] if label == "delivery_marker" else sym[label]
        rows.append(gate.tracefmt.func_record(n, pc, 2, regs, seg, sysregs=sysregs))
    trace = gate.tracefmt.Trace(gate.tracefmt.header(producer, "func", sys=True), rows)
    count = len(rows)
    stderr = (f"tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after {count} retired in 99 clocks\n"
              f"tb: retired {count} instructions in 99 clocks (bus: 3 reads, 2 writes)\n"
              "tb: M7.3b win95 co-sim: 0 IN reads serviced (0 dev_in available, cursor at 0), "
              "1 OUT writes consumed, 0 port/size desync(s), isa-debug-exit reached\n")
    return trace, sym, bytes(image), stderr


class ClosedWitnessTests(unittest.TestCase):
    def setUp(self):
        self.trace, self.sym, self.image, self.stderr = synthetic(1)

    def grade(self, **changes):
        return gate.grade_native(changes.get("trace", self.trace), changes.get("stdout", ""),
                                 changes.get("stderr", self.stderr), changes.get("case", 1),
                                 changes.get("sym", self.sym), changes.get("image", self.image),
                                 changes.get("return_code", 133))

    def test_four_positive_contracts(self):
        for case in range(1, 5):
            trace, sym, image, stderr = synthetic(case)
            receipt = self.grade(trace=trace, sym=sym, image=image, stderr=stderr, case=case)
            self.assertEqual(receipt["write_watchpoint_traps"], 0 if case == 4 else 1)

    def test_actual_wait_not_cap_or_guest_failure(self):
        for code in (0, 135, -15, 124, True):
            with self.assertRaises(ValueError):
                self.grade(return_code=code)

    def test_actual_prepop_width_flags_and_bases(self):
        for key, value in (("esp", 0x7000), ("ebx", 0x5000), ("ebp", 0), ("eflags", 0x102),
                           ("ds", 0x20), ("fs", 0x10), ("ss", 0x18)):
            trace = copy.deepcopy(self.trace)
            trace.records[0][key] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_completed_pop_before_trap_frame(self):
        for index in (1, 2, 3):
            for value in (0x6FF0, 0x6FF2, 0x7000):
                trace = copy.deepcopy(self.trace)
                trace.records[index]["esp"] = gate.tracefmt.h32(value)
                with self.assertRaises(ValueError):
                    self.grade(trace=trace)

    def test_tf_vm_rf_are_not_write_watchpoint_evidence(self):
        for index in (1, 2, 3, 9):
            for value in (0x102, 0x10002, 0x20002):
                trace = copy.deepcopy(self.trace)
                trace.records[index]["eflags"] = gate.tracefmt.h32(value)
                with self.assertRaises(ValueError):
                    self.grade(trace=trace)

    def test_saved_ip_cs_flags_and_actual_dr6(self):
        for index, key in ((4, "edi"), (5, "edx"), (6, "ebp"), (7, "esi")):
            trace = copy.deepcopy(self.trace)
            trace.records[index][key] = "0x00000001"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_missing_duplicate_or_wrong_order_handler(self):
        for first, second in ((2, 9), (1, 2)):
            trace = copy.deepcopy(self.trace)
            trace.records[first]["pc"], trace.records[second]["pc"] = trace.records[second]["pc"], trace.records[first]["pc"]
            with self.assertRaises(ValueError):
                self.grade(trace=trace)
        trace = copy.deepcopy(self.trace)
        trace.records[2]["pc"] = trace.records[9]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_delivery_marker_and_first_mov_distinct_effects(self):
        for index, key, value in ((2, "ecx", 0x6FF4), (3, "ecx", 0),
                                  (2, "eax", 1), (3, "edx", 8), (2, "cr2", 1)):
            trace = copy.deepcopy(self.trace)
            trace.records[index][key] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_negative_case_must_never_execute_handler(self):
        trace, sym, image, stderr = synthetic(4)
        trace.records[0]["pc"] = gate.tracefmt.h32(sym["db_handler"])
        with self.assertRaises(ValueError):
            self.grade(trace=trace, sym=sym, image=image, stderr=stderr, case=4)

    def test_terminal_witness_and_guest_fail_path(self):
        for key in ("eax", "ebx", "ecx", "esp", "ebp", "esi", "edi", "edx", "ss", "ds", "fs", "cr2", "cr3"):
            trace = copy.deepcopy(self.trace)
            trace.records[-1][key] = "0x00000003"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)
        trace = copy.deepcopy(self.trace)
        trace.records[-1]["pc"] = gate.tracefmt.h32(self.sym["fail"])
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_exact_non_esp_opcode_and_flat_next_ip(self):
        image = bytearray(self.image)
        image[0x1001:0x1003] = b"\x04\x24"
        with self.assertRaises(ValueError):
            self.grade(image=bytes(image))
        sym = dict(self.sym, expected_frame_ip=self.sym["tested_end"] - 0xF0000)
        with self.assertRaises(ValueError):
            self.grade(sym=sym)

    def test_closed_logs_faults_and_no_duplicate_footer(self):
        footer = self.stderr.splitlines(keepends=True)[1]
        for changes in (dict(stderr=self.stderr.rstrip()), dict(stdout="%Error: assertion\n"),
                        dict(stderr=self.stderr.replace(footer, "")), dict(stderr=self.stderr + footer),
                        dict(stdout="[FAULT] vec=13 err=00000000 pc=000f1000 state=37 v86=0 depth=0\n"),
                        dict(stderr=self.stderr.replace("99 clocks", "98 clocks", 1)),
                        dict(stderr=self.stderr.replace("0 port/size desync(s)", "1 port/size desync(s)"))):
            with self.assertRaises(ValueError):
                self.grade(**changes)

    def test_golden_free_exit_and_unique_generator_footer(self):
        trace, sym, image, _ = synthetic(1, "qemu-gdbstub")
        log = f"[gen_trace] wrote {len(trace.records)} records to trace (guest exited, code=0)\n"
        self.assertEqual(gate.grade_golden(trace, log, 1, sym, image, 0, 133), len(trace.records))
        for changes in (dict(generator_code=1), dict(free_code=0), dict(log=log + log), dict(log=log.rstrip())):
            values = dict(log=log, generator_code=0, free_code=133)
            values.update(changes)
            with self.assertRaises(ValueError):
                gate.grade_golden(trace, values["log"], 1, sym, image,
                                  values["generator_code"], values["free_code"])

    def test_case_selector_closed_set(self):
        self.assertEqual(run_gate.selected_cases("all"), [1, 2, 3, 4])
        self.assertEqual(run_gate.selected_cases("1,4"), [1, 4])
        for value in ("", "5", "0", "1,1", "1,", "all,1"):
            with self.assertRaises(ValueError):
                run_gate.selected_cases(value)
        for value in (True, "1", 0, 5):
            with self.assertRaises(ValueError):
                gate.variant(value)


if __name__ == "__main__":
    unittest.main()
