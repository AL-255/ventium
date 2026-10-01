#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only synthetic contract negatives; never simulation evidence."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_witness as gate
import run_gate


def synthetic(case, producer="rtl"):
    info = gate.variant(case)
    sym = dict(info, tested_int3=0xF1000, int3_end=0xF1001,
               frame_handler=0xF1100, tested_iret=0xF1200,
               capture_ip=0xF1110, capture_cs=0xF1120, capture_flags=0xF1130,
               do_exit=0xF14F0, set_exit_port=0xF14FC, do_out=0xF1500,
               fail=0xF1600, expected_frame_ip=0x1001)
    image = bytearray(65536)
    image[0x1000] = 0xCC
    op = b"\x66\xcf" if info["word_gate"] else b"\xcf"
    image[0x1200:0x1200 + len(op)] = op
    image[0x14FC:0x1501] = b"\x66\xba\xf4\x00\xee"
    gpr = dict(eax=0x42, ebx=case, ecx=info["handler_esp"],
               esp=info["initial_esp"], ebp=1, esi=0x1001, edi=8, edx=0xF4)
    seg = dict(cs=8, ss=0x20, ds=0x10, es=0x10, fs=0x10, gs=0x10)
    sysregs = dict(cr0=1, cr2=0, cr3=0, cr4=0)
    rows = []
    for n, pc in enumerate((0x1000, 0x1100, 0x1200, 0x14FC)):
        regs = dict(gpr)
        if n < 2:
            regs["esp"] = info["handler_esp"]
        rows.append(gate.tracefmt.func_record(n, pc, 2, regs, seg, sysregs=sysregs))
    trace = gate.tracefmt.Trace(gate.tracefmt.header(producer, "func", sys=True), rows)
    stderr = ("tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 4 retired in 99 clocks\n"
              "tb: retired 4 instructions in 99 clocks (bus: 3 reads, 2 writes)\n"
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

    def test_eight_positive_synthetic_contracts(self):
        for case in range(1, 9):
            trace, sym, image, stderr = synthetic(case)
            with self.subTest(case=case):
                self.assertEqual(self.grade(trace=trace, sym=sym, image=image,
                                            stderr=stderr, case=case)["canonical_faults"], 0)

    def test_actual_exit_is_not_quiescence_or_failed_guest(self):
        for code in (0, 135, -15, 124):
            with self.assertRaises(ValueError):
                self.grade(return_code=code)

    def test_unexpected_and_spliced_fault_logs(self):
        for line in ("[FAULT] vec=12 err=00000000 pc=00001000 state=37 v86=0 depth=0\n",
                     "[FAULT] vec=12 err=00000000 pc=00001000 tb: splice state=37 v86=0 depth=0\n"):
            with self.assertRaises(ValueError):
                self.grade(stdout=line)

    def test_truncated_and_fatal_logs(self):
        for changes in (dict(stderr=self.stderr.rstrip()), dict(stdout="%Error: assertion\n")):
            with self.assertRaises(ValueError):
                self.grade(**changes)

    def test_missing_duplicate_and_wrong_native_footer(self):
        footer = self.stderr.splitlines(keepends=True)[1]
        for text in (self.stderr.replace(footer, ""), self.stderr + footer,
                     self.stderr.replace("after 4 retired", "after 3 retired")):
            with self.assertRaises(ValueError):
                self.grade(stderr=text)

    def test_missing_duplicate_and_desynchronized_io(self):
        footer = self.stderr.splitlines(keepends=True)[-1]
        for text in (self.stderr.replace(footer, ""), self.stderr + footer,
                     self.stderr.replace("0 port/size", "1 port/size")):
            with self.assertRaises(ValueError):
                self.grade(stderr=text)

    def test_no_fake_high_half_preservation(self):
        for index, value in ((0, 0xFF4), (2, 0x1000), (3, 0x1000)):
            trace = copy.deepcopy(self.trace)
            trace.records[index]["esp"] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_no_frame_transition_or_selector_substitution(self):
        for index, key in ((0, "cs"), (0, "ss"), (2, "cs"), (2, "ss")):
            trace = copy.deepcopy(self.trace)
            trace.records[index][key] = "0x0000"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_wrong_terminal_frame_witnesses(self):
        for key in ("eax", "ebx", "ecx", "ebp", "esi", "edi", "edx", "ss", "ds", "cr2", "cr3"):
            trace = copy.deepcopy(self.trace)
            trace.records[-1][key] = "0x00000003"
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_unpaged_protected_mode_required(self):
        for value in (0, 0x80000001):
            trace = copy.deepcopy(self.trace)
            trace.records[-1]["cr0"] = gate.tracefmt.h32(value)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_entry_handler_return_must_be_unique_and_ordered(self):
        trace = copy.deepcopy(self.trace)
        trace.records[1]["pc"] = "0x00001000"
        with self.assertRaises(ValueError):
            self.grade(trace=trace)
        trace = copy.deepcopy(self.trace)
        trace.records[0]["pc"], trace.records[1]["pc"] = trace.records[1]["pc"], trace.records[0]["pc"]
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_in_guest_failure_rejected(self):
        trace = copy.deepcopy(self.trace)
        trace.records[-1]["pc"] = gate.tracefmt.h32(self.sym["fail"] - 0xF0000)
        with self.assertRaises(ValueError):
            self.grade(trace=trace)

    def test_truncated_noncontiguous_or_malformed_trace(self):
        for change in (lambda t: t.records.pop(),
                       lambda t: t.records[1].update(n=3),
                       lambda t: t.records[0].update(eax="0x100000000")):
            trace = copy.deepcopy(self.trace)
            change(trace)
            with self.assertRaises(ValueError):
                self.grade(trace=trace)

    def test_exact_opcodes_sizes_and_input_constants(self):
        for offset in (0x1000, 0x1200, 0x14FC):
            image = bytearray(self.image)
            image[offset] ^= 1
            with self.assertRaises(ValueError):
                self.grade(image=bytes(image))
        sym = dict(self.sym, handler_esp=0xFF4)
        with self.assertRaises(ValueError):
            self.grade(sym=sym)

    def test_golden_requires_closure_and_native_exit(self):
        trace, sym, image, _ = synthetic(1, "qemu-gdbstub")
        log = "[gen_trace] wrote 4 records to /tmp/q.vtrace (guest exited, code=0)\n"
        self.assertEqual(gate.grade_golden(trace, log, 1, sym, image, 0, 133), 4)
        for text, code in (("", 133), (log + log, 133), (log, 135)):
            with self.assertRaises(ValueError):
                gate.grade_golden(trace, text, 1, sym, image, 0, code)

    def test_case_selector_and_actual_profile(self):
        self.assertEqual(run_gate.selected_cases("1,5"), [1, 5])
        for text in ("0", "9", "1,1", "all,1"):
            with self.assertRaises(ValueError):
                run_gate.selected_cases(text)
        from types import SimpleNamespace
        args = SimpleNamespace(tb=None, tb_sha256=None, compile_record=None,
                               compile_sha256=None, compile_cwd=None)
        with patch.object(gate.contracts, "validate_build", return_value=[]):
            with self.assertRaises(ValueError):
                run_gate.validate_profile(args)
        with patch.object(gate.contracts, "validate_build", return_value=["VEN_SEG_ENFORCE"]):
            self.assertEqual(run_gate.validate_profile(args), ["VEN_SEG_ENFORCE"])

    @unittest.skipUnless(os.environ.get("PINTSTACKWRAP_IMAGES"), "requires fresh host-assembled images")
    def test_eight_actual_host_elf_and_bios_contracts(self):
        output = Path(os.environ["PINTSTACKWRAP_IMAGES"])
        for case in range(1, 9):
            sym = gate.contracts.symbols(output / f"pintstackwrap-c{case}.elf")
            gate.validate_image(case, sym, (output / f"pintstackwrap-c{case}.bin").read_bytes())

    def test_existing_or_symlink_output_is_rejected_before_assembly(self):
        with tempfile.TemporaryDirectory(prefix="ventium-pintstackwrap-host.") as directory:
            parent = Path(directory)
            existing = parent / "existing"
            existing.mkdir()
            marker = existing / "keep"
            marker.write_bytes(b"original fixture\n")
            alias = parent / "alias"
            alias.symlink_to(existing, target_is_directory=True)
            for output in (existing, alias):
                result = subprocess.run(
                    ["make", "-C", str(gate.HERE), f"OUTDIR={output}", "all", "-j2"],
                    capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("-DCASE=", result.stdout)
                self.assertEqual(marker.read_bytes(), b"original fixture\n")
                self.assertEqual(list(existing.iterdir()), [marker])


if __name__ == "__main__":
    unittest.main()
