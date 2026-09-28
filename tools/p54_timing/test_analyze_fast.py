#!/usr/bin/env python3
"""AP-500 form tests for the independent, partial gameplay-byte annotator."""

from pathlib import Path
from dataclasses import replace
from itertools import count
import tempfile
import unittest

from analyze_fast import analyze, classify
from pair_bound import pairable


_instances = count(1)


def insn(hex_bytes: str):
    return replace(classify(bytes.fromhex(hex_bytes), 0x1000, False)[0],
                   instance=next(_instances))


class AnalyzeFastTests(unittest.TestCase):
    def test_ap500_memory_pair_and_register_hazards(self):
        self.assertTrue(pairable(insn("8b06"), insn("8b5604")))
        self.assertFalse(pairable(insn("b801000000"), insn("01d8")))
        self.assertTrue(pairable(insn("50"), insn("53")))

    def test_ap500_special_and_nonpairable_forms(self):
        self.assertTrue(pairable(insn("39d8"), insn("75fc")))
        self.assertTrue(pairable(insn("01d8"), insn("75fc")))
        self.assertEqual(insn("d1e8").pipe, "PU")
        self.assertEqual(insn("d3e0").pipe, "NP")
        self.assertEqual(insn("85c0").pipe, "UV")
        self.assertEqual(insn("8506").pipe, "NP")
        self.assertEqual(insn("6689d8").pipe, "PU")
        self.assertTrue(insn("c7460401000000").displacement_and_immediate)

    def test_ordinal_gap_never_creates_a_pair(self):
        header = "cycle\tlegacy_ordinal\tpc\tphysical_start\tslot\towner\tmode16\tbytes\n"
        contiguous = ("1\t1\t1000\t2000\tU\tfresh\t0\t89d8\n"
                      "1\t2\t1002\t2002\tV\tfresh\t0\t89ca\n")
        with tempfile.TemporaryDirectory(prefix="p54-fast-annotate.") as temp:
            path = Path(temp) / "fast.tsv"
            path.write_text(header + contiguous)
            result = analyze(path)
            self.assertEqual(result["selected_adjacent_pairs_conservative"], 1)
            self.assertEqual(result["selected_pair_classes"]["reg_reg"], 1)
            path.write_text(header + contiguous.replace("\t2\t1002", "\t3\t1002"))
            self.assertEqual(analyze(path)["selected_adjacent_pairs_conservative"], 0)

    def test_page_offset_bank_evidence_is_used(self):
        header = "cycle\tlegacy_ordinal\tpc\tphysical_start\tslot\towner\tmode16\tbytes\tdata_bank\n"
        # mov eax,[esi]; mov edx,[esi+4] are independent P54 memory reads.
        rows = ("1\t1\t1000\t2000\tU\tfresh\t0\t8b06\t3\n"
                "1\t2\t1002\t2002\tV\tfresh\t0\t8b5604\t3\n")
        with tempfile.TemporaryDirectory(prefix="p54-fast-bank.") as temp:
            path = Path(temp) / "bank.tsv"
            path.write_text(header + rows)
            result = analyze(path)
            self.assertEqual(result["selected_pair_classes"]["mem_mem"], 1)
            self.assertEqual(result["top_mem_mem_forms"][0],
                             {"u": "mov:8b", "v": "mov:8b", "pairs": 1})
            self.assertEqual(result["selected_bank_conflicts_known"], 1)
            self.assertEqual(result["selected_bank_conflicts_unknown"], 0)
            path.write_text(header + rows.replace("\t3\n", "\t\n", 1))
            self.assertEqual(analyze(path)["selected_bank_conflicts_unknown"], 1)


if __name__ == "__main__":
    unittest.main()
