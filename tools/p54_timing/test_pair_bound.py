#!/usr/bin/env python3
"""Directed Intel AP-500 §5.6 pairing-rule tests; not a timing RTL oracle."""

from dataclasses import replace
import unittest

from pair_bound import Insn, bank_conflict, max_adjacent_pairs, pairable


def op(instance: int, **changes) -> Insn:
    base = Insn("UV", 0, 0, False, False, 0, False, None, 0, False,
                None, instance, False)
    return replace(base, **changes)


class PairBoundTests(unittest.TestCase):
    def test_ap500_sequence_3_paired_loads_and_stores(self):
        # AP-500 §3.6 explicitly pairs both independent loads and stores.
        load0 = op(0, gpr_reads=1, gpr_writes=4, addr_reads=1,
                   memory=True, physical_address=0x4000)
        load1 = op(1, gpr_reads=1, gpr_writes=2, addr_reads=1,
                   memory=True, physical_address=0x4004)
        self.assertTrue(pairable(load0, load1))
        self.assertFalse(bank_conflict(load0, load1))
        store0 = op(2, gpr_reads=5, addr_reads=1, memory=True, physical_address=0x4000)
        store1 = op(3, gpr_reads=3, addr_reads=1, memory=True, physical_address=0x4004)
        self.assertTrue(pairable(store0, store1))

    def test_raw_waw_antidependency_and_partial_registers(self):
        self.assertFalse(pairable(op(0, gpr_writes=1), op(1, gpr_reads=1)))
        self.assertFalse(pairable(op(0, gpr_writes=1), op(1, gpr_writes=1)))
        self.assertTrue(pairable(op(0, gpr_reads=1), op(1, gpr_writes=1)))
        # AL and AH are both represented by the EAX bit (AP-500 §5.6.3).
        self.assertFalse(pairable(op(0, gpr_writes=1), op(1, gpr_writes=1)))

    def test_flags_and_special_pairs(self):
        self.assertTrue(pairable(op(0, flags_write=True), op(1, flags_write=True)))
        self.assertFalse(pairable(op(0, flags_write=True), op(1, flags_read=True)))
        self.assertTrue(pairable(op(0, flags_write=True, special="cmp_jcc"),
                                 op(1, pipe="PV", flags_read=True, special="cmp_jcc")))
        self.assertFalse(pairable(op(0, pipe="PV"), op(1)))
        self.assertFalse(pairable(op(0), op(1, pipe="PU")))
        self.assertFalse(pairable(op(0, gpr_writes=1, special="cmp_jcc"),
                                  op(1, pipe="PV", gpr_reads=1, special="cmp_jcc")))
        self.assertTrue(pairable(op(0, gpr_writes=16, special="push_push"),
                                 op(1, gpr_reads=16, gpr_writes=16, special="push_push")))
        self.assertFalse(pairable(op(0, gpr_writes=17, special="push_push"),
                                  op(1, gpr_reads=17, special="push_push")))

    def test_prefix_and_disp_imm(self):
        # AP-500 §5.5: U prefix decode costs clocks but can still pair.
        self.assertTrue(pairable(op(0, pipe="PU", prefixes=1), op(1)))
        self.assertFalse(pairable(op(0, displacement_and_immediate=True), op(1)))

    def test_bank_conflict_delays_but_does_not_forbid(self):
        u = op(0, memory=True, physical_address=0x1000)
        v = op(1, memory=True, physical_address=0x2020)
        self.assertTrue(pairable(u, v))
        self.assertTrue(bank_conflict(u, v))

    def test_matching_not_greedy_and_boundaries(self):
        # 0-1 and 1-2 are legal; 2-3 is legal. Optimal is two pairs.
        self.assertEqual(max_adjacent_pairs([op(i) for i in range(4)]), (4, 2, 0))
        self.assertEqual(max_adjacent_pairs([op(0, boundary_after=True), op(1)]), (2, 0, 0))
        self.assertEqual(max_adjacent_pairs([op(0), op(0)]), (2, 0, 0))

    def test_annotations_fail_closed(self):
        with self.assertRaises(ValueError):
            Insn.from_json({"pipe": "UV"})
        with self.assertRaises(ValueError):
            Insn.from_json({**op(0).__dict__, "memory": True})


if __name__ == "__main__":
    unittest.main()
