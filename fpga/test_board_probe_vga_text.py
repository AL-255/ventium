#!/usr/bin/env python3
"""Regression for the sparse B8000 observation-ring renderer.

This is deliberately pure: it exercises no board hardware or /dev/mem.  The
ring is newest-first, while a reconstruction must apply records oldest-first
so the most recent observed value wins.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import unittest


PROBE_PATH = Path(__file__).with_name("board-tools") / "ven_board_probe.py"
SPEC = importlib.util.spec_from_file_location("ven_board_probe", PROBE_PATH)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class SparseVgaRingTextTest(unittest.TestCase):
    def test_reconstructs_known_cells_and_latest_value_wins(self) -> None:
        # Ring order is newest first.  The oldest dword provides A + space,
        # the newest byte overwrites A with B, and the remaining byte adds Z.
        entries = [
            {"core_address": "000b8004", "data": "0000005a"},
            {"core_address": "000b8000", "data": "00000042"},
            {"core_address": "000b8000", "data": "07200741"},
        ]
        self.assertEqual(probe._sparse_vga_ring_lines(entries), ["00:00-02 B Z"])

    def test_avoids_fabricating_zero_extended_bytes(self) -> None:
        # A byte-wide observation carries no trustworthy attribute/next-cell
        # bytes, despite being presented in a 32-bit data field.
        entries = [{"core_address": "000b8000", "data": "00000051"}]
        self.assertEqual(probe._sparse_vga_ring_lines(entries), ["00:00-00 Q"])

    def test_indexed_ring_reads_restore_newest_selector(self) -> None:
        # Both readers may select historical slots, but must leave the shared
        # selector at zero so a later read-only ``sample`` is genuinely newest.
        ctrl = bytearray(0x300)
        probe.read_pc_ring(ctrl, 2)
        self.assertEqual(struct.unpack_from("<I", ctrl, probe.W_DBG_CTL)[0], 0)
        probe.read_core_observe_ring(ctrl, 2)
        self.assertEqual(struct.unpack_from("<I", ctrl, probe.W_DBG_CTL)[0], 0)


if __name__ == "__main__":
    unittest.main()
