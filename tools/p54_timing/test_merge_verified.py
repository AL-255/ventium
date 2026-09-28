#!/usr/bin/env python3
"""Fail-closed slow-byte owner and decode validation tests."""

import unittest

import capstone

from merge_verified import slow_reason


class MergeVerifiedTests(unittest.TestCase):
    def setUp(self):
        self.decoders = {0: capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32),
                         1: capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)}
        self.row = {"legacy_ordinal": "10", "pc": "1000", "mode16": "0", "bytes": "c3"}

    def test_owner_and_length_must_both_match(self):
        self.assertEqual(slow_reason(self.row, {10: 0x1000}, self.decoders), "accepted")
        self.assertEqual(slow_reason(self.row, {}, self.decoders), "unreported_owner")
        self.assertEqual(slow_reason(self.row, {10: 0x1001}, self.decoders), "owner_pc_mismatch")
        self.assertEqual(slow_reason({**self.row, "bytes": "c705e4060600"},
                                     {10: 0x1000}, self.decoders), "instruction_length_mismatch")
        self.assertEqual(slow_reason({**self.row, "mode16": "2"},
                                     {10: 0x1000}, self.decoders), "invalid_code_mode")


if __name__ == "__main__":
    unittest.main()
