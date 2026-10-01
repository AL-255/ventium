#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only negative grading fixtures. Never launch QEMU, RTL, or a build."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pverrw_gate", HERE / "run-pverrw-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
t = gate.tracefmt


def fixture(case=1, producer="rtl"):
    # Use the reviewed real manifest, but synthetic records ONLY to exercise
    # host rejection paths. These records are never architectural evidence.
    manifest = json.loads((gate.FIXTURES / "manifest.json").read_text())
    variant = copy.deepcopy(next(v for v in manifest["variants"] if v["case"] == case))
    sym = dict(do_out=0xF0104, real_do_out=0xF0203,
               query_expected=variant["queries"], fault_expected=variant["faults"],
               v86_start=0xF0300, db_handler=0xF0800)
    for n, item in enumerate(variant.get("expected_faults", [])):
        sym[item["symbol"]] = 0xF0400 + 8*n
    for n, item in enumerate(variant.get("expected_traps", [])):
        sym[item["symbol"]] = 0xF0900 + 8*n
        sym[item["end_symbol"]] = sym[item["symbol"]] + 3
    bios = bytearray(65536)
    bios[0x100:0x105] = b"\x66\xba\xf4\x00\xee"
    bios[0x200:0x204] = b"\xba\xf4\x00\xee"
    pcs = [0xFFF0]
    if case == 8:
        for item in variant["expected_traps"]:
            pcs += [sym[item["symbol"]], sym["db_handler"], sym[item["end_symbol"]]]
    pcs.append(0x203 if case == 5 else 0xF0104)
    gpr = dict(eax=0x42, ecx=variant["queries"], edx=0xF4, ebx=case,
               esp=0x90000, ebp=variant["faults"], esi=0x600D0F00, edi=0)
    seg = dict(cs=8, ss=0x10, ds=0x10, es=0x10, fs=0x10, gs=0x10)
    rows = [t.func_record(n, pc, 0xCD5, gpr, seg,
                         sysregs=dict(cr0=1, cr2=0x21000, cr3=0x11000, cr4=0))
            for n, pc in enumerate(pcs)]
    trace = t.Trace(t.header(producer, "func", sys=True), rows)
    faults = gate.expected_faults(variant, sym)
    log = "".join(f"[FAULT] vec={vec} err={err:08x} pc={pc:08x} state=2 v86=0 depth=0\n"
                  for vec, err, pc in faults)
    log += (f"tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after {len(rows)} retired in 100 clocks\n"
            f"tb: retired {len(rows)} instructions in 100 clocks (bus: 4 reads, 2 writes)\n"
            "tb: M7.3b win95 co-sim: 0 IN reads serviced (0 dev_in available, cursor at 0), "
            "1 OUT writes consumed, 0 port/size desync(s), isa-debug-exit reached\n")
    return trace, log, sym, variant, bytes(bios)


class GradingTests(unittest.TestCase):
    def grade(self, data, code=133):
        return gate.grade_native(*data, code)

    def test_all_ten_contracts_pass_host_synthetic(self):
        for case in range(1, 11):
            with self.subTest(case=case):
                self.assertEqual(self.grade(fixture(case))["case"], case)

    def test_non133_reap_rejected(self):
        for code in (0, 135, -15, 124):
            with self.subTest(code=code), self.assertRaises(ValueError):
                self.grade(fixture(), code)

    def test_bad_headers_rejected(self):
        for key, value in (("producer", "qemu-gdbstub"), ("vtrace", 2),
                           ("mode", "cycle"), ("sys", False), ("x87", True)):
            data = fixture()
            data[0].hdr[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.grade(data)

    def test_noncontiguous_records(self):
        data = fixture()
        data[0].records[-1]["n"] = 3
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_boolean_sequence_not_integer(self):
        data = fixture()
        data[0].records[0]["n"] = False
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_missing_or_out_of_range_fields(self):
        for key in t.func_compare_keys(False, True):
            with self.subTest(key=key):
                data = fixture()
                del data[0].records[0][key]
                with self.assertRaises(ValueError):
                    self.grade(data)
                data = fixture()
                data[0].records[0][key] = hex(1 << t._WIDTH[key])
                with self.assertRaises(ValueError):
                    self.grade(data)

    def test_missing_final_witness(self):
        for key in ("eax", "ebx", "ecx", "ebp", "esi", "edi", "edx", "pc"):
            data = fixture()
            data[0].records[-1][key] = "0x12345678"
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.grade(data)

    def test_instruction_cap_rejected(self):
        data = fixture()
        data[0].records *= gate.MAX_INSN
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_empty_trace_rejected(self):
        data = fixture()
        data[0].records.clear()
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_missing_or_duplicate_stop_and_footer(self):
        original = fixture()[1]
        for log in ("\n".join(original.splitlines()[:-1])+"\n",
                    original + original, original.replace("100 clocks", "101 clocks", 1),
                    original.replace("after 2 retired", "after 3 retired"),
                    original.replace("WIN95 co-sim isa-debug-exit (out 0xf4)", "instruction cap"),
                    original.rstrip("\n")):
            data = list(fixture())
            data[1] = log
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.grade(data)

    def test_assertion_fatal_rejected(self):
        data = list(fixture())
        data[1] += "%Error: Assertion failed\n"
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_missing_duplicate_wrong_io_closure(self):
        data = fixture()
        line = data[1].splitlines(True)[-1]
        for log in (data[1].replace(line, ""), data[1] + line,
                    data[1].replace("0 port/size", "1 port/size"),
                    data[1].replace("1 OUT writes", "2 OUT writes"),
                    data[1].replace(", isa-debug-exit reached", ""),
                    data[1].replace("0 IN reads", "1 IN reads")):
            changed = list(data)
            changed[1] = log
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.grade(changed)

    def test_canonical_fault_grammar_and_stderr_splice(self):
        trace, log, sym, variant, image = fixture(3)
        first = log.splitlines(True)[0]
        for malformed in (first.replace(" state=2", " junk=2"),
                          first.replace(" v86=0", " v86=2"),
                          first.replace(" depth=0", " depth=x"),
                          first.rstrip()+" tb: retirement\n",
                          "tb: "+first,
                          first.replace("err=00000000", "err=0"),
                          first.replace(" depth=0", "")):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                self.grade((trace, log.replace(first, malformed), sym, variant, image))

    def test_each_separate_closed_log_requires_eof_newline(self):
        with tempfile.TemporaryDirectory(prefix="pverrw-host-") as tmp:
            path = Path(tmp) / "stdout"
            path.write_text("")
            self.assertEqual(gate.closed_log(path, allow_empty=True), "")
            with self.assertRaises(ValueError):
                gate.closed_log(path)
            path.write_text("[FAULT] vec=14 truncated")
            with self.assertRaises(ValueError):
                gate.closed_log(path, allow_empty=True)
            path.write_text("closed\n")
            self.assertEqual(gate.closed_log(path), "closed\n")

    def test_wrong_missing_reordered_and_extra_faults(self):
        data = fixture(10)
        lines = data[1].splitlines(True)
        for log in ("".join(lines[1:]), "".join([lines[1], lines[0], *lines[2:]]),
                    data[1] + lines[0], data[1].replace("vec=13", "vec=14", 1),
                    data[1].replace("err=00000000", "err=00000001", 1),
                    data[1].replace("pc=000f0400", "pc=000f0401", 1),
                    data[1] + "[FAULT] truncated\n"):
            changed = list(data)
            changed[1] = log
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.grade(changed)

    def test_real_and_v86_fault_owner(self):
        for case in (5, 6):
            trace, log, sym, variant, bios = fixture(case)
            fault = variant["expected_faults"][0]
            want = sym[fault["symbol"]] - (0xF0000 if case == 5 else sym["v86_start"])
            self.assertEqual(gate.expected_faults(variant, sym)[0][2], want)
            variant["expected_faults"][0]["pc_mode"] = "flat"
            with self.assertRaises(ValueError):
                self.grade((trace, log, sym, variant, bios))

    def test_weakened_manifest_or_elf_counts_rejected(self):
        data = fixture(3)
        data[3]["expected_faults"].clear()
        with self.assertRaises(ValueError):
            self.grade(data)
        data = fixture(1)
        data[2]["query_expected"] = 49
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_elf_image_exit_mismatch_rejected(self):
        data = list(fixture())
        data[-1] = bytes(65536)
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_tf_handler_missing_extra_reordered_rejected(self):
        for alteration in ("missing", "extra", "reorder", "resume"):
            data = fixture(8)
            rows = data[0].records
            if alteration == "missing":
                rows[2]["pc"] = t.h32(0)
            elif alteration == "extra":
                rows[3]["pc"] = t.h32(data[2]["db_handler"])
            elif alteration == "reorder":
                rows[1]["pc"], rows[4]["pc"] = rows[4]["pc"], rows[1]["pc"]
            else:
                rows[3]["pc"] = t.h32(0)
            with self.subTest(alteration=alteration), self.assertRaises(ValueError):
                self.grade(data)

    def test_tf_no_ordinary_start_fault(self):
        data = list(fixture(8))
        data[1] += "[FAULT] vec=1 err=00000000 pc=000f0900\n"
        with self.assertRaises(ValueError):
            self.grade(data)

    def test_golden_requires_real_native133_and_footer(self):
        data = fixture(1, "qemu-gdbstub")
        good = "[gen_trace] wrote 2 records to /output/qemu.vtrace (guest exited, code=0)\n"
        self.assertEqual(gate.grade_golden(data[0], good, *data[2:], 0, 133), 2)
        for log, code, free in ((good, 0, 0), (good, 1, 133),
                                (good.replace("code=0", "code=135"), 0, 133),
                                (good.replace("2 records", "3 records"), 0, 133),
                                (good+good, 0, 133), (good.rstrip(), 0, 133)):
            with self.subTest(log=log, code=code, free=free), self.assertRaises(ValueError):
                gate.grade_golden(data[0], log, *data[2:], code, free)

    def test_trace_file_newline_and_json_completeness(self):
        with tempfile.TemporaryDirectory(prefix="pverrw-host-") as tmp:
            path = Path(tmp) / "trace.vtrace"
            data = fixture()[0]
            complete = "\n".join(t.dumps(obj) for obj in [data.hdr, *data.records])+"\n"
            path.write_text(complete)
            self.assertEqual(len(gate.read_complete_trace(path).records), 2)
            path.write_text(complete.rstrip("\n"))
            with self.assertRaises(ValueError):
                gate.read_complete_trace(path)
            path.write_text(complete + '{"n":\n')
            with self.assertRaises(ValueError):
                gate.read_complete_trace(path)


class ProfileAndSelectionTests(unittest.TestCase):
    def test_actual_profile_pin_and_seg_define(self):
        with tempfile.TemporaryDirectory(prefix="pverrw-build-host-") as tmp:
            root = Path(tmp)
            tb = root / "tb_ventium"
            # A text placeholder is NEVER executed; only read/hash/profile
            # functions run in these host negative fixtures.
            tb.write_text("host placeholder only\n")
            tb.chmod(0o700)
            meta = root / "Vventium_top__verFiles.dat"
            meta.write_text(f'C "verilator --top-module ventium_top -Mdir {root} +define+VEN_SEG_ENFORCE"\n')
            result = gate.validate_build(tb, gate.digest(tb), meta, gate.digest(meta), [10])
            self.assertIn("VEN_SEG_ENFORCE", result)
            with self.assertRaises(ValueError):
                gate.validate_build(tb, "0"*64, meta, gate.digest(meta), [1])
            with self.assertRaises(ValueError):
                gate.validate_build(tb, gate.digest(tb), meta, "0"*64, [1])
            meta.write_text(f'C "verilator --top-module ventium_top -Mdir {root}"\n')
            gate.validate_build(tb, gate.digest(tb), meta, gate.digest(meta), [9])
            with self.assertRaises(ValueError):
                gate.validate_build(tb, gate.digest(tb), meta, gate.digest(meta), [10])

    def test_relative_mdir_anchored_to_compile_cwd(self):
        with tempfile.TemporaryDirectory(prefix="pverrw-build-host-") as tmp:
            root = Path(tmp)
            out = root / "obj_dir_fake"
            out.mkdir()
            tb, meta = out / "tb_ventium", out / "Vventium_top__verFiles.dat"
            tb.write_text("never executed\n")
            tb.chmod(0o700)
            meta.write_text('C "verilator --top-module ventium_top -Mdir obj_dir_fake"\n')
            gate.validate_build(tb, gate.digest(tb), meta, gate.digest(meta), [1], root)
            with self.assertRaises(ValueError):
                gate.validate_build(tb, gate.digest(tb), meta, gate.digest(meta), [1], out)

    def test_malformed_duplicate_wrongtop_profiles(self):
        for text in ('C "verilator"\n', 'C "verilator --top-module other -Mdir x"\n',
                     'C "verilator --top-module ventium_top -Mdir x"',
                     'C "verilator --top-module ventium_top -Mdir x"\n'*2,
                     'C "verilator --top-module ventium_top -Mdir x -Mdir y"\n'):
            if not text.endswith("\n") and text.count("-Mdir") == 1:
                continue  # Compile metadata need not be newline-terminated.
            with self.subTest(text=text), self.assertRaises(ValueError):
                gate.compile_profile(text)

    def test_selection_rejects_duplicates_empty_unknown(self):
        self.assertEqual(gate.parse_cases("first7"), list(range(1, 8)))
        self.assertEqual(gate.parse_cases("all"), list(range(1, 11)))
        self.assertEqual(gate.parse_cases("8,9,10"), [8, 9, 10])
        for value in ("", "0", "11", "1,1", "1 2", "1,", "01", "all,1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                gate.parse_cases(value)


if __name__ == "__main__":
    unittest.main()
