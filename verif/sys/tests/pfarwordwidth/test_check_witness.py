#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only synthetic tracefmt negative checks; never DUT evidence."""
import copy
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import check_witness as gate
import run_gate


def synthetic(case, producer="rtl"):
    info = gate.variant(case)
    sym = dict(info, tested_op=0xF1000, callee=0xF1300, retf_resume=0xF1200,
               do_exit=0xF14F0, do_out=0xF1500, fault_fail32=0xF0200)
    prefix = b"\x66" if (info["frame_bytes"] == 2) == bool(info["code_d"]) else b""
    op = prefix + (b"\xcb" if info["operation_kind"] else b"\x9a" + (sym["callee"] - 0xF0000).to_bytes(
        info["frame_bytes"], "little") + info["expected_frame_cs"].to_bytes(2, "little"))
    sym["call_resume"] = sym["tested_op"] + len(op)
    sym["expected_frame_ip"] = sym["retf_resume" if info["operation_kind"] else "call_resume"] - 0xF0000
    port = b"\x66\xba\xf4\x00" if info["code_d"] else b"\xba\xf4\x00"
    sym["set_exit_port"] = sym["do_out"] - len(port)
    image = bytearray(65536)
    image[0x1000:0x1000 + len(op)] = op
    start = sym["set_exit_port"] - 0xF0000
    image[start:start + len(port) + 1] = port + b"\xee"
    for n, name in enumerate(("capture_load_ip", "capture_load_cs", "capture_guard_before",
                              "capture_guard_after", "capture_fault_count")):
        sym[name] = 0xF1600 + n * 8
        image[0x1600 + n * 8:0x1603 + n * 8] = b"\x67\x66\x8b"
    gpr = dict(eax=0x42, ebx=case, ecx=info["expected_esp"], esp=info["expected_esp"],
               ebp=0, esi=sym["expected_frame_ip"], edi=info["expected_frame_cs"], edx=0xF4)
    seg = dict(cs=info["expected_frame_cs"], ss=0x20, ds=0x10, es=0x10, fs=0x10, gs=0x10)
    sysregs = dict(cr0=1 | (info["boundary_kind"] << 31), cr2=0,
                   cr3=0x11000 if info["boundary_kind"] else 0, cr4=0)
    rows = [gate.tracefmt.func_record(n, pc, 2, gpr, seg, sysregs=sysregs)
            for n, pc in enumerate((0x1000, sym["set_exit_port"] - 0xF0000))]
    trace = gate.tracefmt.Trace(gate.tracefmt.header(producer, "func", sys=True), rows)
    stderr = ("tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 2 retired in 99 clocks\n"
              "tb: retired 2 instructions in 99 clocks (bus: 3 reads, 2 writes)\n"
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

    def test_all_32_positive_synthetic_contracts(self):
        for case in range(1, 33):
            with self.subTest(case=case):
                trace, sym, image, stderr = synthetic(case)
                self.assertEqual(self.grade(trace=trace, sym=sym, image=image,
                                            stderr=stderr, case=case)["canonical_faults"], 0)

    def test_wrong_actual_exit(self):
        for code in (0, 135, -15, 124):
            with self.assertRaises(ValueError):
                self.grade(return_code=code)

    def test_unexpected_fault(self):
        with self.assertRaises(ValueError):
            self.grade(stdout="[FAULT] vec=12 err=00000000 pc=00001000 state=34 v86=0 depth=0\n")

    def test_malformed_spliced_fault(self):
        with self.assertRaises(ValueError):
            self.grade(stdout="[FAULT] vec=12 err=00000000 pc=00001000 tb: split state=34 v86=0 depth=0\n")

    def test_no_final_newline(self):
        with self.assertRaises(ValueError):
            self.grade(stderr=self.stderr.rstrip())

    def test_missing_and_duplicate_footer(self):
        for text in (self.stderr.replace("tb: retired 2 instructions in 99 clocks (bus: 3 reads, 2 writes)\n", ""),
                     self.stderr + "tb: retired 2 instructions in 99 clocks (bus: 3 reads, 2 writes)\n"):
            with self.assertRaises(ValueError):
                self.grade(stderr=text)

    def test_wrong_footer_count(self):
        with self.assertRaises(ValueError):
            self.grade(stderr=self.stderr.replace("after 2 retired", "after 3 retired"))

    def test_missing_desync_or_duplicate_io_footer(self):
        io = self.stderr.splitlines(keepends=True)[-1]
        for text in (self.stderr.replace(io, ""), self.stderr.replace("0 port/size", "1 port/size"), self.stderr + io):
            with self.assertRaises(ValueError):
                self.grade(stderr=text)

    def test_fatal_log(self):
        with self.assertRaises(ValueError):
            self.grade(stdout="%Error: unexpected native assertion\n")

    def test_bad_esp_high_half(self):
        trace = copy.deepcopy(self.trace)
        trace.records[-1]["esp"] = "0x0000fffc"
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_wrong_witness_and_selector(self):
        for key in ("eax", "esi", "edi", "cs", "ss", "cr2", "cr3"):
            trace = copy.deepcopy(self.trace)
            trace.records[-1][key] = "0x00000001"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_missing_or_repeated_transfer(self):
        for pc in (0x1001, self.sym["tested_op"] - 0xF0000):
            trace = copy.deepcopy(self.trace)
            if pc == 0x1001:
                trace.records[0]["pc"] = gate.tracefmt.h32(pc)
            else:
                trace.records[-1]["pc"] = gate.tracefmt.h32(pc)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_incomplete_or_noncontiguous_trace(self):
        for change in ("missing", "n", "range", "header"):
            trace = copy.deepcopy(self.trace)
            if change == "missing":
                del trace.records[0]["fs"]
            elif change == "n":
                trace.records[1]["n"] = 9
            elif change == "range":
                trace.records[0]["eax"] = "0x100000000"
            else:
                trace.hdr["sys"] = False
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_corrupt_or_mismatched_image_and_elf(self):
        image = bytearray(self.image)
        image[0x1000] = 0xCB
        with self.assertRaises(ValueError):
            self.grade(image=bytes(image))
        sym = dict(self.sym, frame_bytes=4)
        with self.assertRaises(ValueError):
            self.grade(sym=sym)

    def test_cs16_memory_witness_requires_address32(self):
        image = bytearray(self.image)
        image[self.sym["capture_guard_after"] - 0xF0000] = 0x66
        with self.assertRaises(ValueError):
            self.grade(image=bytes(image))

    def test_actual_profile_required_not_environment(self):
        class Args:
            tb = Path("unused")
            tb_sha256 = "0" * 64
            compile_record = Path("unused")
            compile_sha256 = "0" * 64
            compile_cwd = Path("unused")
        with patch.object(gate.contracts, "validate_build", return_value=[]):
            with self.assertRaises(ValueError):
                run_gate.validate_profile(Args, [1])
            self.assertEqual(run_gate.validate_profile(Args, [3]), [])
        with patch.object(gate.contracts, "validate_build", return_value=["VEN_SEG_ENFORCE"]):
            self.assertIn("VEN_SEG_ENFORCE", run_gate.validate_profile(Args, [1]))

    def test_stale_hash_rejected(self):
        with patch.object(gate.contracts, "digest", return_value="1" * 64):
            with self.assertRaises(ValueError):
                gate.contracts.pin(Path("unused"), "0" * 64)

    def test_golden_requires_free_exit_and_complete_footer(self):
        trace, sym, image, _ = synthetic(1, "qemu-gdbstub")
        log = "[gen_trace] wrote 2 records to /fixture/qemu.vtrace (guest exited, code=0)\n"
        self.assertEqual(gate.grade_golden(trace, log, 1, sym, image, 0, 133), 2)
        for generator, free, text in ((1, 133, log), (0, 135, log), (0, 133, ""), (0, 133, log + log)):
            with self.assertRaises(ValueError):
                gate.grade_golden(trace, text, 1, sym, image, generator, free)

    def test_case_selection_rejects_invalid_and_duplicate(self):
        self.assertEqual(len(run_gate.selected_cases("all")), 32)
        self.assertEqual(run_gate.selected_cases("1,32"), [1, 32])
        for text in ("0", "33", "1,1", "1,", "all,1"):
            with self.assertRaises(ValueError):
                run_gate.selected_cases(text)

    @unittest.skipUnless(os.environ.get("PFARWORDWIDTH_IMAGES"), "host-built image directory not provided")
    def test_all_real_host_elf_bios_contracts(self):
        images = Path(os.environ["PFARWORDWIDTH_IMAGES"])
        for case in range(1, 33):
            with self.subTest(case=case):
                sym = gate.contracts.symbols(images / f"pfarwordwidth-c{case}.elf")
                gate.validate_image(case, sym, (images / f"pfarwordwidth-c{case}.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
