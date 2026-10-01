#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only synthetic contract negatives; never DUT/QEMU execution evidence."""
import copy
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import check_witness as gate
import run_gate


def synthetic(case, producer="rtl"):
    info = gate.variant(case)
    opcode = b"\xbc\x00\x00\xad\xde" if case == 1 else b"\x8d\x20"
    sym = dict(info, set_tf_popfl=0xF1000, tested_op=0xF1001,
               tested_end=0xF1001 + len(opcode), db_handler=0xF1100,
               capture_ip=0xF1110, capture_cs=0xF1120, capture_flags=0xF1130,
               capture_dr6=0xF1140, clear_saved_tf=0xF1150, tested_iret=0xF1200,
               do_exit=0xF14F0, set_exit_port=0xF14FC, do_out=0xF1500, fail=0xF1600)
    sym["expected_frame_ip"] = sym["tested_end"] - 0xF0000
    image = bytearray(65536)
    image[0x1000] = 0x9D
    image[0x1001:0x1001 + len(opcode)] = opcode
    image[0x1200] = 0xCF
    image[0x14FC:0x1501] = b"\x66\xba\xf4\x00\xee"
    gpr = dict(eax=0x42, ebx=case, ecx=info["handler_esp"], esp=info["destination_esp"],
               ebp=1, esi=info["expected_dr6"], edi=sym["expected_frame_ip"], edx=0xF4)
    seg = dict(cs=8, ss=0x20, ds=0x10, es=0x10, fs=0x10, gs=0x10)
    sysregs = dict(cr0=1, cr2=0, cr3=0, cr4=0)
    labels = ("set_tf_popfl", "tested_op", "db_handler", "capture_ip", "capture_cs",
              "capture_flags", "capture_dr6", "clear_saved_tf", "tested_iret", "tested_end", "set_exit_port")
    rows = []
    for n, label in enumerate(labels):
        regs = dict(gpr)
        flags = 2
        if n == 0:
            regs["esp"] = info["initial_esp"]
            flags = 0x102
        elif n < 8:
            regs["esp"] = info["handler_esp"]
        if label == "capture_cs":
            regs["edx"] = 8
        if label == "capture_flags":
            regs["ebp"] = 0x102
        rows.append(gate.tracefmt.func_record(n, sym[label] - 0xF0000, flags, regs, seg, sysregs=sysregs))
    trace = gate.tracefmt.Trace(gate.tracefmt.header(producer, "func", sys=True), rows)
    stderr = ("tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 11 retired in 99 clocks\n"
              "tb: retired 11 instructions in 99 clocks (bus: 3 reads, 2 writes)\n"
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

    def test_two_positive_synthetic_contracts(self):
        for case in (1, 2):
            trace, sym, image, stderr = synthetic(case)
            self.assertEqual(self.grade(trace=trace, sym=sym, image=image, stderr=stderr, case=case)["tf_traps"], 1)

    def test_actual_wait_not_quiescence_or_guest_failure(self):
        for code in (0, 135, -15, 124):
            with self.assertRaises(ValueError):
                self.grade(return_code=code)

    def test_premature_popfl_trap_or_tf_not_set(self):
        for changes in (dict(esp="0xDEADFFF4"), dict(eflags="0x00000002")):
            trace = copy.deepcopy(self.trace)
            trace.records[0].update(changes)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_swallowed_explicit_high_half_and_stale_borrow(self):
        for value in (0xBEEFFFF4, 0xDEACFFF4, 0x0000FFF4):
            trace = copy.deepcopy(self.trace)
            trace.records[1]["esp"] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_live_tf_or_rf_not_cleared_at_handler(self):
        for value in (0x102, 0x10002, 0x20002):
            trace = copy.deepcopy(self.trace)
            trace.records[2]["eflags"] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_actual_frame_ip_cs_flags_and_dr6_readback(self):
        for index, key in ((3, "edi"), (4, "edx"), (5, "ebp"), (6, "esi")):
            trace = copy.deepcopy(self.trace)
            trace.records[index][key] = "0x00000001"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_saved_tf_and_restored_high_half(self):
        for changes in (dict(esp="0xDEAC0000"), dict(esp="0xBEEF0000"), dict(eflags="0x00000102")):
            trace = copy.deepcopy(self.trace)
            trace.records[8].update(changes)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_missing_duplicate_or_out_of_order_traps(self):
        trace = copy.deepcopy(self.trace)
        trace.records[9]["pc"] = "0x00001100"
        with self.assertRaises(ValueError):
            self.grade(trace=trace)
        trace = copy.deepcopy(self.trace)
        trace.records[1]["pc"], trace.records[2]["pc"] = trace.records[2]["pc"], trace.records[1]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_terminal_witnesses(self):
        for key in ("eax", "ebx", "ecx", "esp", "ebp", "esi", "edi", "edx", "ss", "ds", "cr2", "cr3"):
            trace = copy.deepcopy(self.trace)
            trace.records[-1][key] = "0x00000003"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_in_guest_failure_rejected(self):
        trace = copy.deepcopy(self.trace)
        trace.records[-1]["pc"] = gate.tracefmt.h32(self.sym["fail"] - 0xF0000)
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_unexpected_and_spliced_canonical_faults(self):
        for line in ("[FAULT] vec=12 err=00000000 pc=00001001 state=37 v86=0 depth=0\n",
                     "[FAULT] vec=12 err=00000000 pc=00001001 tb: splice state=37 v86=0 depth=0\n"):
            with self.assertRaises(ValueError):
                self.grade(stdout=line)

    def test_truncated_fatal_missing_or_duplicate_native_closure(self):
        footer = self.stderr.splitlines(keepends=True)[1]
        for changes in (dict(stderr=self.stderr.rstrip()), dict(stdout="%Error: assertion\n"),
                        dict(stderr=self.stderr.replace(footer, "")), dict(stderr=self.stderr + footer)):
            with self.assertRaises(ValueError):
                self.grade(**changes)

    def test_io_closure_desync_and_wrong_retire_count(self):
        io = self.stderr.splitlines(keepends=True)[-1]
        for text in (self.stderr.replace(io, ""), self.stderr + io,
                     self.stderr.replace("0 port/size", "1 port/size"),
                     self.stderr.replace("after 11 retired", "after 10 retired")):
            with self.assertRaises(ValueError):
                self.grade(stderr=text)

    def test_truncated_noncontiguous_or_out_of_range_trace(self):
        for change in (lambda t: t.records.pop(), lambda t: t.records[1].update(n=3),
                       lambda t: t.records[0].update(eax="0x100000000")):
            trace = copy.deepcopy(self.trace)
            change(trace)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_actual_elf_bios_opcodes_and_adjacent_popfl(self):
        for offset in (0x1000, 0x1001, 0x1200, 0x14FC):
            image = bytearray(self.image)
            image[offset] ^= 1
            with self.assertRaises(ValueError):
                self.grade(image=bytes(image))
        sym = dict(self.sym, destination_esp=0xBEEF0000)
        with self.assertRaises(ValueError):
            self.grade(sym=sym)

    def test_complete_golden_and_real_guest_exit_required(self):
        trace, sym, image, _ = synthetic(1, "qemu-gdbstub")
        log = "[gen_trace] wrote 11 records to /tmp/q.vtrace (guest exited, code=0)\n"
        self.assertEqual(gate.grade_golden(trace, log, 1, sym, image, 0, 133), 11)
        for text, code in (("", 133), (log + log, 133), (log, 135)):
            with self.assertRaises(ValueError):
                gate.grade_golden(trace, text, 1, sym, image, 0, code)

    def test_case_selector_and_actual_profile(self):
        self.assertEqual(run_gate.selected_cases("all"), [1, 2])
        for text in ("0", "3", "1,1", "all,1"):
            with self.assertRaises(ValueError):
                run_gate.selected_cases(text)
        from types import SimpleNamespace
        args = SimpleNamespace(tb=None, tb_sha256=None, compile_record=None,
                               compile_sha256=None, compile_cwd=None)
        with patch.object(gate.contracts, "validate_build", return_value=[]):
            with self.assertRaises(ValueError):
                run_gate.validate_profile(args)

    @unittest.skipUnless(os.environ.get("PESPDEBUGWRAP_IMAGES"), "requires fresh host-assembled images")
    def test_two_actual_host_elf_bios_contracts_and_unconditional_freshness(self):
        output = Path(os.environ["PESPDEBUGWRAP_IMAGES"])
        for case in (1, 2):
            sym = gate.contracts.symbols(output / f"pespdebugwrap-c{case}.elf")
            gate.validate_image(case, sym, (output / f"pespdebugwrap-c{case}.bin").read_bytes())
        # No assembly is launched: this phony prerequisite must reject an
        # existing OUTDIR even when all real targets are already up to date.
        result = subprocess.run(["make", "-s", "-C", gate.HERE, f"OUTDIR={output}", "validate-output"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
