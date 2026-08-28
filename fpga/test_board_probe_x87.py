#!/usr/bin/env python3
"""Regression for the compact x87 halted-state decoder.

This does not touch /dev/mem.  It emulates only the selector/data handshake
used by ven_board_probe.read_halted_arch_state(), including an EMPTY physical
slot at TOP, so word order and logical ST(i) reconstruction stay explicit.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import unittest
from types import SimpleNamespace


PROBE_PATH = Path(__file__).with_name("board-tools") / "ven_board_probe.py"
SPEC = importlib.util.spec_from_file_location("ven_board_probe", PROBE_PATH)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class CompactX87StateTest(unittest.TestCase):
    def test_manual_halt_clears_a_stale_breakpoint_latch(self) -> None:
        """HALT must request the core stop without leaving an old BP cause armed."""
        class ClosableBytes(bytearray):
            def close(self) -> None:
                pass

        ctrl = ClosableBytes(0x300)
        original_open_mmio = probe.open_mmio
        original_require = probe.require_exec_debug
        original_wait = probe.wait_execution_halted
        original_close = probe.os.close
        seen: list[int] = []

        def fake_wait(mapping: bytearray, expected: bool, _timeout: float) -> int:
            self.assertTrue(expected)
            seen.append(struct.unpack_from("<I", mapping, probe.R_DBG_EXEC_CTRL)[0])
            return probe.DBG_EXEC_HALTED

        try:
            probe.open_mmio = lambda writable: (-1, ctrl, 0)
            probe.require_exec_debug = lambda _ctrl: None
            probe.wait_execution_halted = fake_wait
            probe.os.close = lambda _fd: None
            self.assertEqual(probe.halt_probe(SimpleNamespace(timeout=0.1)), 0)
        finally:
            probe.open_mmio = original_open_mmio
            probe.require_exec_debug = original_require
            probe.wait_execution_halted = original_wait
            probe.os.close = original_close

        self.assertEqual(seen, [probe.DBG_EXEC_HALT_REQ | probe.DBG_EXEC_BP_CLR])

    def test_physical_words_and_logical_top_mapping(self) -> None:
        ctrl = bytearray(0x300)
        # TOP=6; physical FPR6 is EMPTY.  Every physical slot receives a
        # distinct 80-bit marker, making an ordering/reassembly bug observable.
        top = 6
        tags = 1 << top
        words: dict[int, int] = {
            17: 0x1234_037F,
            18: (top << 8) | tags,
            43: 0x0012_3456,
            44: 0x0087_6543,
            45: 0xBEEF_CAFE,
            46: 0x1111_0000, 47: 0x2222_0000, 48: 0x3333_0000,
            49: 0x4444_0000, 50: 0x5555_0000, 51: 0x6666_0000,
            52: 0x000F_FFFF, 53: 0x0000_FFFF, 54: 0x0FFF_FFFF,
            55: 0x00FF_FFFF, 56: 0x0000_FFFF, 57: 0xFFFF_FFFF,
            58: 0x0093_009B,
            59: (0b10_0001 << 16) | 0x0000_0093,
            60: 0x0010_0000, 61: 0x0020_0000,
            62: 0x0FFF_07FF, 63: 0x0040_0038,
            64: 0x1000_0000, 65: 0x1000_0001, 66: 0x1000_0002,
            67: 0x1000_0003, 68: 0xFFFF_0FF0, 69: 0x0000_0400,
            70: 0x00AB_C000, 71: 0x0000_0067, 72: 0x0000_0189,
            73: 0x0012_3000, 74: 0x0000_00EF, 75: 0x0000_0003,
        }
        values = []
        for physical in range(8):
            value = (0x3FFF + physical) << 64 | (0x1122_3344_5566_7788 + physical)
            values.append(value)
            base = 19 + physical * 3
            words[base] = value & 0xFFFF_FFFF
            words[base + 1] = (value >> 32) & 0xFFFF_FFFF
            words[base + 2] = (value >> 64) & 0xFFFF

        original_u32 = probe.u32
        original_execution_ctrl = probe.execution_ctrl

        def fake_u32(mapping: bytearray, offset: int) -> int:
            if offset == probe.R_DBG_ARCH_DATA:
                selector = struct.unpack_from("<I", mapping, probe.R_DBG_ARCH_SEL)[0] & 0x7F
                return words.get(selector, 0)
            return original_u32(mapping, offset)

        try:
            probe.u32 = fake_u32
            probe.execution_ctrl = lambda _ctrl: probe.DBG_EXEC_HALTED
            observed = probe.read_halted_arch_state(ctrl)
        finally:
            probe.u32 = original_u32
            probe.execution_ctrl = original_execution_ctrl

        self.assertEqual(observed["ftop"], 6)
        self.assertEqual(observed["fctrl"], "037f")
        self.assertEqual(observed["fstat"], "1234")
        self.assertEqual(observed["fip"], "00123456")
        self.assertEqual(observed["fcs"], "cafe")
        self.assertEqual(observed["fds"], "beef")
        self.assertEqual(observed["x87_physical"][2]["floatx80"], f"{values[2]:020x}")
        self.assertTrue(observed["x87_physical"][6]["empty"])
        self.assertEqual(observed["x87_logical"][0]["physical"], 6)
        self.assertTrue(observed["x87_logical"][0]["empty"])
        self.assertEqual(observed["x87_logical"][3]["physical"], 1)
        self.assertEqual(observed["x87_logical"][3]["floatx80"], f"{values[1]:020x}")
        self.assertEqual(observed["segments"]["cs"], {
            "selector": "0000", "base": "11110000", "limit": "000fffff", "attr": "9b", "b": True
        })
        self.assertEqual(observed["segments"]["fs"], {
            "selector": "0000", "base": "55550000", "limit": "0000ffff", "attr": "93", "b": False
        })
        self.assertEqual(observed["gdt_base"], "00100000")
        self.assertEqual(observed["idt_limit"], "0fff")
        self.assertEqual(observed["ldt_selector"], "0038")
        self.assertEqual(observed["tr_selector"], "0040")
        self.assertEqual(observed["dr7"], "00000400")
        self.assertEqual(observed["tr_base"], "00abc000")
        self.assertEqual(observed["tr_limit"], "00000067")
        self.assertTrue(observed["tr_valid"])
        self.assertEqual(observed["tr_attr"], "89")
        self.assertEqual(observed["ldt_base"], "00123000")
        self.assertEqual(observed["ldt_limit"], "00ef")
        self.assertEqual(observed["stop_reason"], "single-step")


if __name__ == "__main__":
    unittest.main()
