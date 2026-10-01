#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only invariants: legalize segment offsets, not linear coverage."""

import hashlib
from pathlib import Path
import unittest

import gen_cases as gen


def legacy_layouts():
    """Independent pre-legalization matrix, without calling gen's planner.

    Rows are (kind, B, slots, flags, SP, base, denial).  Keep the original
    ESP=2/base=0 rows here: replacing them would defeat the coverage proof.
    """
    rows = []

    def append(kind, b32, count, flags, sp, base, deny_all=True):
        width = 2 if flags & 2 else 4
        slots = reference_slots(sp, count, width, b32, base)
        denials = reference_pages(slots) if deny_all else [None]
        rows.extend((kind, b32, count, flags, sp, base, deny) for deny in denials)

    for kind, trap, err in ((1, 0, 0), (1, 1, 0), (2, 0, 1), (2, 1, 1)):
        count = 6 if err else 5
        flags = 2 | (4 if trap else 0) | (1 if err else 0)
        for base in (0x80000, 0x80FF0, 0x80FFC):
            for sp in range(count * 2 + 1):
                append(kind, 0, count, flags, sp, base)
    for sp in (0, 2, 4, 8, 12, 16, 20):
        append(1, 1, 5, 0, sp, 0)
    for sp in (2, 8):
        append(3, 1, 35, 0, sp, 0)
    for gate16 in (True, False):
        sps = (0, 34, 68, 70) if gate16 else (0, 68, 136, 140)
        for base in (0x80000, 0x80FFC):
            for sp in sps:
                append(3, 0, 35, 2 if gate16 else 0, sp, base)
    append(4, 0, 9, 0, 8, 0x80FFC, False)
    append(5, 0, 10, 0, 4, 0x80FFC, False)
    append(4, 1, 9, 0, 8, 0, False)
    return rows


def reference_slots(sp, count, width, b32, base):
    """Per-slot linear BYTES, including a possible 32-bit linear wrap."""
    mask = (1 << (32 if b32 else 16)) - 1
    result = []
    for k in range(count):
        offset = (sp - width * (k + 1)) & mask
        result.append(tuple((base + offset + byte) & 0xFFFFFFFF
                            for byte in range(width)))
    return result


def reference_pages(slots):
    result = []
    for slot in slots:
        for addr in slot:
            page = addr & 0xFFFFF000
            if page not in result:
                result.append(page)
    return result


def reference_fault(slots, deny):
    if deny is None:
        return None, None
    for k, slot in enumerate(slots):
        if any(addr & 0xFFFFF000 == deny for addr in slot):
            return k, slot[0] if slot[0] & 0xFFFFF000 == deny else deny
    raise AssertionError("reference denial is not touched")


class GeneratorTests(unittest.TestCase):
    def test_entire_original_linear_byte_matrix_is_preserved(self):
        old = legacy_layouts()
        new = gen.pxwrap_cases()
        self.assertEqual(len(old), 351)
        self.assertEqual(len(new), len(old))
        relocated = []
        for i, (before, after) in enumerate(zip(old, new)):
            kind, b32, count, flags, sp, base, deny = before
            with self.subTest(case=i + 1):
                self.assertEqual((after.kind, after.b32, after.nslots,
                                  after.flags, after.deny),
                                 (kind, b32, count, flags, deny))
                width = 2 if flags & 2 else 4
                original = reference_slots(sp, count, width, b32, base)
                current = reference_slots(after.esp0, count, width,
                                          b32, after.ss_base)
                self.assertEqual(current, original)
                self.assertEqual(gen.pages_in_order(after.slots, width),
                                 reference_pages(original))
                self.assertEqual((after.k_fault, after.cr2),
                                 reference_fault(original, deny))
                for _, offset, _ in after.slots:
                    self.assertLessEqual(offset + width - 1, 0xFFFFFFFF)
                if (after.esp0, after.ss_base) != (sp, base):
                    self.assertEqual((b32, sp, base), (1, 2, 0))
                    self.assertEqual((after.esp0, after.ss_base), (0, 2))
                    relocated.append(i + 1)
        self.assertEqual(relocated, [304, 305, 315, 316])

    def test_counts_and_v86_controls_are_unchanged(self):
        cases = gen.pxwrap_cases()
        self.assertEqual(sum(c.deny is not None for c in cases), 348)
        self.assertEqual(2 * sum(c.kind == gen.KIND_GP and c.deny is not None
                                 for c in cases), 332)
        self.assertEqual(sum(c.deny is None for c in cases), 3)

    def test_relocated_first_slot_still_straddles_linear_four_gib(self):
        for kind, count in ((gen.KIND_INT, 5), (gen.KIND_CG, 35)):
            case = gen.Case(kind, 1, count, 0, 0, 2, None)
            self.assertEqual(case.slots[0], (0, 0xFFFFFFFC, 0xFFFFFFFE))
            self.assertEqual(reference_slots(0, count, 4, 1, 2)[0],
                             (0xFFFFFFFE, 0xFFFFFFFF, 0, 1))
            self.assertEqual(gen.pages_in_order(case.slots, 4),
                             [0xFFFFF000, 0])

    def test_illegal_old_dword_operand_is_rejected_not_masked(self):
        for sp in (1, 2, 3):
            for kind, count in ((gen.KIND_INT, 5), (gen.KIND_CG, 35)):
                with self.subTest(sp=sp, kind=kind):
                    with self.assertRaisesRegex(ValueError, "segment offset limit"):
                        gen.Case(kind, 1, count, 0, sp, 0, None)

    def test_illegal_word_operand_is_also_rejected(self):
        with self.assertRaisesRegex(ValueError, "segment offset limit"):
            gen.Case(gen.KIND_INT, 1, 5, gen.FL_G16, 1, 0, None)

    def test_b0_sp_wrap_is_not_a_64k_segment_limit(self):
        case = gen.Case(gen.KIND_INT, 0, 5, gen.FL_G16, 1, 0x80000, None)
        self.assertEqual(case.slots[0], (0, 0xFFFF, 0x8FFFF))
        self.assertEqual(gen.slot_pages(case.slots[0][2], 2), [0x8F000, 0x90000])

    def test_generated_pxwrap_table_matches_current_matrix(self):
        cases = gen.pxwrap_cases()
        text = Path(__file__).with_name("pxwrap_cases.inc").read_text()
        self.assertIn(".equ NCASES, 351\n", text)
        self.assertEqual(text.split("case_table:\n", 1)[1],
                         "".join(c.inc() + "\n" for c in cases))

    def test_pxwrapm_generated_bytes_remain_pinned(self):
        path = Path(__file__).resolve().parent.parent / "pxwrapm" / "pxwrapm_cases.inc"
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                         "ee6041e62f37c5176fc13281e5bf126f627063b3ea17621770ab51689718a349")


if __name__ == "__main__":
    unittest.main()
