#!/usr/bin/env python3
"""Tiny host-only fixture checks. No simulator or golden producer is launched."""
import json
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
BASE = 0xF0000


def symbols(case):
    result = subprocess.run(["nm", "-n", str(HERE / f"pverrw-c{case}.elf")],
                            check=True, stdout=subprocess.PIPE, text=True,
                            timeout=3)
    return {parts[2]: int(parts[0], 16) for row in result.stdout.splitlines()
            if len(parts := row.split()) == 3}


def byte_window(case, name):
    table = symbols(case)
    data = (HERE / f"pverrw-c{case}.bin").read_bytes()
    return data[table[name] - BASE:table[name + "_end"] - BASE]


class BuiltFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((HERE / "manifest.json").read_text())

    def test_all_images_reset_size_counts(self):
        for variant in self.manifest["variants"]:
            case = variant["case"]
            with self.subTest(case=case):
                table = symbols(case)
                data = (HERE / variant["image"]).read_bytes()
                self.assertEqual(len(data), 65536)
                self.assertEqual(data[0xfff0:0xfff5], b"\xea\x00\x00\x00\xf0")
                self.assertEqual(table["_start16"], BASE)
                self.assertEqual(table["_reset"], 0xffff0)
                self.assertEqual(table["query_expected"], variant["queries"])
                self.assertEqual(table["fault_expected"], variant["faults"])

    def test_pm32_register_prefix_lengths(self):
        self.assertEqual(byte_window(1, "rw3_r"), bytes.fromhex("0f00e0"))
        self.assertEqual(byte_window(1, "rw3_w"), bytes.fromhex("0f00e8"))
        self.assertEqual(byte_window(1, "reg_r66"), bytes.fromhex("660f00e0"))
        self.assertEqual(byte_window(1, "reg_w66"), bytes.fromhex("660f00e8"))

    def test_pm32_memory_prefix_lengths(self):
        expected = dict(mem_r="0f002500900000", mem_w="0f002d00900000",
                        mem_r66="660f002500900000", mem_w66="660f002d00900000",
                        mem_r67="670f0027", mem_w67="670f002f",
                        mem_r6667="66670f0027", mem_w6667="66670f002f")
        for name, raw in expected.items():
            with self.subTest(name=name):
                self.assertEqual(byte_window(1, name), bytes.fromhex(raw))

    def test_pm16_memory_and_register_lengths(self):
        expected = dict(pm16_r="0f00e0", pm16_w66="660f00e8",
                        pm16_mem_r="0f00260090", pm16_mem_w66="660f002e0090",
                        pm16_mem_r67="670f002500900000",
                        pm16_mem_w6667="66670f002d00900000")
        for name, raw in expected.items():
            with self.subTest(name=name):
                self.assertEqual(byte_window(7, name), bytes.fromhex(raw))
        table = symbols(7)
        self.assertEqual(table["pm16_entry_off"], table["pm16_entry"] - BASE)

    def test_operand_controls_are_at_exact_word_boundary(self):
        self.assertEqual(byte_window(3, "edge_word_r"), bytes.fromhex("0f0025fe0f0200"))
        self.assertEqual(byte_window(3, "edge_word_w66"), bytes.fromhex("660f002dfe0f0200"))
        table = symbols(3)
        data = (HERE / "pverrw-c3.bin").read_bytes()
        self.assertEqual(data[table["operand_fault1"]-BASE:table["operand_resume1"]-BASE],
                         bytes.fromhex("0f002500100200"))
        self.assertEqual(data[table["operand_fault2"]-BASE:table["operand_resume2"]-BASE],
                         bytes.fromhex("660f002dff0f0200"))

    def test_descriptor_fault_queries_are_register_sources(self):
        table = symbols(4)
        data = (HERE / "pverrw-c4.bin").read_bytes()
        for first, last, raw in (("descriptor_fault1", "descriptor_resume1", "0f00e0"),
                                 ("descriptor_fault2", "descriptor_resume2", "660f00e8")):
            self.assertEqual(data[table[first]-BASE:table[last]-BASE], bytes.fromhex(raw))

    def test_real_mode_offsets_and_invalid_instruction_lengths(self):
        expected = dict(real_r="0f00e0", real_w66="660f00e8",
                        real_mem_r="0f00260090", real_mem_w67="670f002d00100200")
        table = symbols(5)
        for name, raw in expected.items():
            self.assertEqual(byte_window(5, name), bytes.fromhex(raw))
            self.assertEqual(table[name + "_off"], table[name] - BASE)
        self.assertEqual(table["real_ud_handler_off"], table["real_ud_handler"] - BASE)

    def test_v86_memory_query_names_unmapped_operand(self):
        self.assertEqual(byte_window(6, "vm_r"), bytes.fromhex("0f00e0"))
        self.assertEqual(byte_window(6, "vm_mem_w"), bytes.fromhex("0f002e0010"))
        self.assertEqual(byte_window(6, "vm_r66"), bytes.fromhex("660f00e0"))

    def test_semantic_discriminators_are_not_missing_from_image(self):
        table = symbols(1)
        for stem in ("absent_rw", "absent_ro", "system_ldt", "system_tss",
                     "system_gate", "rpl_deny", "null0", "null3", "gdt_oob",
                     "ldt_index0", "ldt_ro", "ldt_absent", "ldt_oob",
                     "conf_read", "conf_exec", "code_read", "code_exec"):
            self.assertIn(stem + "_r", table)
            self.assertIn(stem + "_w", table)
        for stem in ("cpl_deny0", "cpl_deny1", "cpl_conf_read", "cpl_conf_exec",
                     "cpl_absent", "cpl_code0", "cpl_code3"):
            self.assertIn(stem + "_r", symbols(2))
            self.assertIn(stem + "_w", symbols(2))

    def test_host_receipt_does_not_claim_simulated_pass(self):
        self.assertTrue(self.manifest["standalone_only"])
        self.assertTrue(self.manifest["execution_status"].startswith("NOT RUN"))
        self.assertEqual(self.manifest["terminal"]["eax"], "0x42")
        self.assertEqual(self.manifest["terminal"]["ebp"], "variant.faults")
        self.assertGreaterEqual(len(self.manifest["coverage_gaps"]), 4)


if __name__ == "__main__":
    unittest.main()
