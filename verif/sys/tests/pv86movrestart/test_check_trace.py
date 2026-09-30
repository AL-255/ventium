#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Small host-only qualifier tests. Never launch a compiler, QEMU or RTL.

Optional retained-run checks:
  PV86MOVRESTART_ARTIFACT_DIR=/tmp/<approved-run> python3 -B <this-file>
Synthetic traces use canonical tracefmt builders and its JSON-line serializer;
negative cases intentionally corrupt one field of those canonical objects.
"""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_trace as checker  # noqa: E402
from tracefmt import (GPR_KEYS, SEG_KEYS, SYS_CR, cycle_record, dumps,  # noqa: E402
                      func_record, header, read_trace)

ARTIFACT_DIR = os.environ.get("PV86MOVRESTART_ARTIFACT_DIR")


class TimingQualifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(prefix="pv86movrestart-host.", dir="/tmp")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.timing = self.root / "timing.vtrace"
        self.reference = self.root / "reference.vtrace"
        self.pcs = (0xFFF0, 0, 1, 0x2A)
        self.rows = [cycle_record(n, pc, 18 + 7 * n, pipe="U", paired=False)
                     for n, pc in enumerate(self.pcs)]
        self.refs = [func_record(n, pc, 0x23002,
                                 dict.fromkeys(GPR_KEYS, 0),
                                 dict.fromkeys(SEG_KEYS, 0),
                                 sysregs=dict.fromkeys(SYS_CR, 0))
                     for n, pc in enumerate(self.pcs)]
        self.timing_header = header("rtl", "cycle")
        self.reference_header = header("qemu-gdbstub", "func", sys=True)

    @staticmethod
    def write_trace(path: Path, trace_header: dict, rows: list[dict]) -> None:
        # Use the executable canonical serializer, never hand-format JSONL.
        path.write_text("\n".join(dumps(row) for row in [trace_header, *rows]) + "\n")

    def invoke(self) -> None:
        self.write_trace(self.timing, self.timing_header, self.rows)
        self.write_trace(self.reference, self.reference_header, self.refs)
        with redirect_stdout(io.StringIO()):
            checker.check_timing(self.timing, self.reference)

    def reject(self) -> None:
        with self.assertRaises((KeyError, ValueError, TypeError)):
            self.invoke()

    def test_accepts_canonical_unpaired_offset_pc_sequence(self) -> None:
        self.invoke()

    def test_rejects_paired_issue(self) -> None:
        self.rows[1]["paired"] = True
        self.reject()

    def test_rejects_nonboolean_pair_marker(self) -> None:
        for marker in (0, None, "false"):
            with self.subTest(marker=marker):
                self.rows[1]["paired"] = marker
                self.reject()

    def test_rejects_duplicate_clock_even_when_pair_marker_false(self) -> None:
        self.rows[1]["cyc"] = self.rows[0]["cyc"]
        self.reject()

    def test_rejects_decreasing_clock(self) -> None:
        self.rows[1]["cyc"] = self.rows[0]["cyc"] - 1
        self.reject()

    def test_rejects_changed_pc_or_order(self) -> None:
        for pc in (self.pcs[0], 0x10000 + self.pcs[1], 0x12345):
            with self.subTest(pc=pc):
                self.rows[1]["pc"] = cycle_record(1, pc, 25)["pc"]
                self.reject()

    def test_rejects_short_long_or_empty_trace(self) -> None:
        valid = self.rows
        for rows in ([], valid[:-1], valid + [cycle_record(4, 0x2B, 60, pipe="U")]):
            with self.subTest(records=len(rows)):
                self.rows = rows
                self.reject()

    def test_rejects_instruction_cap(self) -> None:
        with patch.object(checker, "MAX_INSN", len(self.rows)):
            self.reject()

    def test_rejects_timing_mode_mismatch(self) -> None:
        for mode in ("func", "unknown", None):
            with self.subTest(mode=mode):
                self.timing_header["mode"] = mode
                self.reject()

    def test_rejects_reference_mode_mismatch(self) -> None:
        for mode in ("cycle", "unknown", None):
            with self.subTest(mode=mode):
                self.reference_header["mode"] = mode
                self.reject()

    def test_rejects_reference_without_literal_system_header(self) -> None:
        for system in (False, None, 1, "true"):
            with self.subTest(system=system):
                self.reference_header["sys"] = system
                self.reject()

    def test_rejects_noncontiguous_timing_index(self) -> None:
        self.rows[2]["n"] = 3
        self.reject()

    def test_rejects_noncontiguous_reference_index(self) -> None:
        self.refs[2]["n"] = 3
        self.reject()

    def test_rejects_missing_reference_index(self) -> None:
        del self.refs[1]["n"]
        self.reject()

    def test_rejects_malformed_reference_index_type(self) -> None:
        for value in (True, 1.0, "1", None):
            with self.subTest(value=value):
                self.refs[1]["n"] = value
                self.reject()

    def test_rejects_malformed_clock_or_index_types(self) -> None:
        for field in ("cyc", "n"):
            original = self.rows[1][field]
            for value in (True, float(original), str(original), None):
                with self.subTest(field=field, value=value):
                    self.rows[1][field] = value
                    self.reject()
            self.rows[1][field] = original

    def test_rejects_missing_timing_fields(self) -> None:
        for field in ("n", "pc", "cyc", "pipe", "paired"):
            with self.subTest(field=field):
                original = self.rows[1].pop(field)
                self.reject()
                self.rows[1][field] = original

    def test_rejects_missing_reference_pc(self) -> None:
        del self.refs[1]["pc"]
        self.reject()

    def test_rejects_non_u_attribution_for_this_fixture(self) -> None:
        for pipe in ("V", "-", None):
            with self.subTest(pipe=pipe):
                self.rows[1]["pipe"] = pipe
                self.reject()

    def test_cli_reports_malformed_timing_failure(self) -> None:
        del self.rows[1]["paired"]
        self.write_trace(self.timing, self.timing_header, self.rows)
        self.write_trace(self.reference, self.reference_header, self.refs)
        argv = ["check_trace.py", "--case", "1", "--symbols", "unused.sym",
                "--timing-only", "--reference", str(self.reference), str(self.timing)]
        stderr = io.StringIO()
        with patch.object(sys, "argv", argv), redirect_stderr(stderr):
            self.assertEqual(checker.main(), 1)
        self.assertIn("PV86-MOVRESTART-TRACE-FAIL", stderr.getvalue())


@unittest.skipUnless(ARTIFACT_DIR, "set PV86MOVRESTART_ARTIFACT_DIR for readonly approved-run checks")
class RetainedCanonicalFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(ARTIFACT_DIR)
        self.assertTrue(self.root.is_dir(), "configured retained artifact directory must exist")

    def test_all_four_retained_timing_witnesses(self) -> None:
        for case in range(1, 5):
            with self.subTest(case=case), redirect_stdout(io.StringIO()):
                base = self.root / f"pv86movrestart_{case}"
                checker.check_timing(Path(f"{base}.timing.vtrace"), Path(f"{base}.qemu.vtrace"))

    def test_all_four_retained_qemu_functional_and_cycle_func_states(self) -> None:
        for case in range(1, 5):
            for producer in ("qemu", "functional", "cycle"):
                with self.subTest(case=case, producer=producer), redirect_stdout(io.StringIO()):
                    base = self.root / f"pv86movrestart_{case}"
                    path = Path(f"{base}.{producer}.vtrace")
                    self.assertEqual(read_trace(str(path)).mode, "func")
                    checker.check(path, Path(f"{base}.sym"), case)


if __name__ == "__main__":
    unittest.main()
