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
            self.assertEqual(analyze(path)["selected_adjacent_pairs_conservative"], 1)
            path.write_text(header + contiguous.replace("\t2\t1002", "\t3\t1002"))
            self.assertEqual(analyze(path)["selected_adjacent_pairs_conservative"], 0)


if __name__ == "__main__":
    unittest.main()
