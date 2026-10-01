#!/usr/bin/env python3
"""Tiny host-only fixture checks. No simulator or golden producer is launched."""
import hashlib
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

    def test_other_nine_images_are_unchanged_by_case7_repair(self):
        original = [
            "32e7a394c5fb649918aca419b78d75a7c3970b8633c77df286cc3fa6be1e4562",
            "1db194e129efb30dd06d2774545fdbb75c60ce706d45fb8d2f12f2861d825769",
            "4123cd0bbe2231672eb00c80bcee55a5d5559a74ffb7dea706c411645c4cf508",
            "bb5a3c549cafbde90a4068720a693fe2c262628716c8326b93c86834e4b15f93",
            "acc21244e19d84b72feb0da476546386457de914962b857e77e1f5f008c4efd1",
            "a342303dc23bacae955d92e033b06bed94bdeac50a0db49cfee9a407cc0e4d91",
            "9675f3548e4325a6e0f7f928f97d745248ff4de528d7775acefe7dfe9c2351e3",
        ]
        for case, digest in enumerate(original, 1):
            if case == 7:
                continue          # historical failing case7 is preserved in the closed run
            with self.subTest(case=case):
                self.assertEqual(hashlib.sha256((HERE / f"pverrw-c{case}.bin").read_bytes()).hexdigest(), digest)
        additions = {
            8: "dc71d04266738af651c71f3dfe3a163fbbd1c32c9e73507d7110ee6f9d8278e3",
            9: "5cfe924d7d05083b1495d0cf9b997a5f158ae92148602736fa78273acf829943",
            10: "9e2de09d5e756890fc913a2fc00df113ead581071929ebd339beb0137fc61112",
        }
        for case, digest in additions.items():
            with self.subTest(case=case):
                self.assertEqual(hashlib.sha256((HERE / f"pverrw-c{case}.bin").read_bytes()).hexdigest(), digest)

    def test_pm16_descriptor_base_limit_and_default_size(self):
        raw = byte_window(7, "pm16_descriptor_high")
        self.assertEqual(raw[:5], bytes.fromhex("66c7065c05"))
        self.assertEqual(len(raw), 9)
        high = int.from_bytes(raw[5:], "little")
        low = 0xffff
        base = ((low >> 16) & 0xffff) | ((high & 0xff) << 16) | (high & 0xff000000)
        limit = (low & 0xffff) | (((high >> 16) & 0xf) << 16)
        self.assertEqual(base, BASE)
        self.assertEqual(limit, 0xffff)
        self.assertEqual(high & 0x00c00000, 0)  # D=0 and G=0; code is truly PM16
        self.assertEqual((high >> 8) & 0xff, 0x9b)

    def test_tf_queries_and_shared_retirement_regressions(self):
        expected = dict(tf_verr_valid="0f00e0", tf_verr_null="0f00e0",
                        tf_verw_valid="0f00e8", tf_verw_ro="0f00e8",
                        tf_lar_valid="0f02c0", tf_lar_null="0f02c0",
                        tf_lsl_valid="0f03c0", tf_lsl_null="0f03c0")
        for name, raw in expected.items():
            with self.subTest(name=name):
                self.assertEqual(byte_window(8, name), bytes.fromhex(raw))
        table = symbols(8)
        self.assertIn("db_handler", table)
        source = (HERE / "pverrw.S").read_text()
        self.assertIn("andl $~0x100,40(%esp)", source)
        self.assertIn("testl $0x10000,40(%esp)", source)
        # LAR excludes descriptor-limit bits19:16 from the high dword.
        self.assertIn("tfq tf_lar_valid,0x18,0x02,0xc0,0x00c0f200", source)
        variant = self.manifest["variants"][7]
        self.assertEqual(variant["expected_faults"], [])
        self.assertEqual(len(variant["expected_traps"]), 8)
        for trap in variant["expected_traps"]:
            self.assertEqual(trap["vector"], 1)
            self.assertEqual(table[trap["end_symbol"]], table[trap["symbol"]] + 3)

    def test_lock_faults_precede_absent_operand_read(self):
        expected = dict(lock_verr_reg="f00f00e0", lock_verw_reg66="f0660f00e8",
                        lock_verr_mem="f00f002500100200", lock_verw_mem66="f0660f002d00100200")
        for name, raw in expected.items():
            with self.subTest(name=name):
                self.assertEqual(byte_window(9, name), bytes.fromhex(raw))
        variant = self.manifest["variants"][8]
        self.assertEqual(variant["oracle"], "intel-spec")
        self.assertIn("not differential", variant["qualification"])
        self.assertEqual([(f["vector"], f["error"]) for f in variant["expected_faults"]], [(6, 0)] * 4)
        self.assertIn("movl $0x77889900,%eax", (HERE / "pverrw.S").read_text())

    def test_segment_faults_use_exact_word_limit_and_explicit_ss(self):
        expected = dict(gp_null_verr="0f002500900000", gp_null_verw66="660f002d00900000",
                        gp_limit_verr="0f0025ff9f0000", gp_limit_verw66="660f002dff9f0000",
                        ss_limit_verr="360f0025ff9f0000", ss_limit_verw66="36660f002dff9f0000",
                        short_ds_legal_verr="0f0025fe9f0000", short_ds_legal_verw="660f002dfe9f0000",
                        short_ss_legal_verr="360f0025fe9f0000", short_ss_legal_verw="360f002dfe9f0000")
        for name, raw in expected.items():
            with self.subTest(name=name):
                self.assertEqual(byte_window(10, name), bytes.fromhex(raw))
        variant = self.manifest["variants"][9]
        self.assertEqual(variant["required_defines"], ["VEN_SEG_ENFORCE"])
        self.assertIn("not differential", variant["qualification"])
        self.assertEqual([(f["vector"], f["error"]) for f in variant["expected_faults"]], [(13, 0)] * 4 + [(12, 0)] * 2)

    def test_expected_event_symbols_and_debug_exit_status(self):
        for variant in self.manifest["variants"]:
            table = symbols(variant["case"])
            for event in variant.get("expected_faults", []):
                self.assertIn(event["symbol"], table)
                if "base_symbol" in event:
                    self.assertIn(event["base_symbol"], table)
        self.assertEqual(self.manifest["exit_code"], (0x42 << 1) | 1)

    def test_directed_receipt_does_not_claim_standard_suite_acceptance(self):
        self.assertTrue(self.manifest["standalone_only"])
        self.assertTrue(self.manifest["execution_status"].startswith("PASS directed all-ten gate"))
        self.assertIn("Standard-suite acceptance remains pending", self.manifest["execution_status"])
        receipt = self.manifest["qualification_receipt"]
        self.assertRegex(receipt["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(receipt["tb_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(receipt["path"],
                         "verif/tb/obj_dir_verrw_oct01.M2bz8N/pverrw-qualified-oct01.2/summary.json")
        # This host check validates the metadata contract, not the referenced
        # simulator result. The parent separately audited that closed receipt.
        for variant in self.manifest["variants"][8:]:
            self.assertEqual(variant["oracle"], "intel-spec")
            self.assertIn("not differential", variant["qualification"])
        self.assertEqual(self.manifest["terminal"]["eax"], "0x42")
        self.assertEqual(self.manifest["terminal"]["ebp"], "variant.faults")
        self.assertGreaterEqual(len(self.manifest["coverage_gaps"]), 2)


if __name__ == "__main__":
    unittest.main()
