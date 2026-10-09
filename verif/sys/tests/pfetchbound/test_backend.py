#!/usr/bin/env python3
"""No model launch: verify explicit runtime backend and activity rejection."""
import os
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_gate as gate


class BackendTest(unittest.TestCase):
    def test_direct_default_is_explicit(self):
        args = SimpleNamespace(l1_axi=False, axi_latency=0)
        self.assertEqual(gate.configure_backend(args, []),
                         dict(name="direct-memory", axi_latency=None))

    def test_axi_missing_define_or_counter_is_rejected(self):
        for defines in ([], ["VEN_L1_AXI"], ["VEN_L1D_PERF"]):
            with self.subTest(defines=defines), self.assertRaises(ValueError):
                gate.configure_backend(SimpleNamespace(l1_axi=True, axi_latency=0), defines)

    def test_axi_resets_inherited_controls(self):
        for latency in (0, 7):
            with self.subTest(latency=latency), patch.dict(os.environ,
                    {"AXI_RLAT":"100", "AXI_WLAT":"99", "AXI_INJECT":"1",
                     "TB_EXTRA_FLAGS":"--snapshot unsafe", "QEMU_CPU":"not-pentium",
                     "VENTIUM_BUILD_SCOPE_ACTIVE":"preserved"}, clear=True):
                result = gate.configure_backend(SimpleNamespace(l1_axi=True, axi_latency=latency),
                                                ["VEN_L1_AXI", "VEN_L1D_PERF"])
                self.assertEqual(result, dict(name="l1-axi", axi_latency=latency))
                self.assertEqual(dict(os.environ),
                                 dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency),
                                      VENTIUM_BUILD_SCOPE_ACTIVE="preserved"))

    def test_actual_counter_format(self):
        self.assertEqual(gate.grade_axi_activity(
            "[L1DPERF] fill cycles=2019 backing-wait=1545 backing-ack=474\n"),
            dict(fill_cycles=2019, backing_wait=1545, backing_ack=474))

    def test_missing_zero_duplicate_or_malformed_counter_rejected(self):
        good = "[L1DPERF] fill cycles=2 backing-wait=1 backing-ack=1\n"
        for log in ("", good + good, good.replace("cycles=2", "cycles=0"),
                    good.replace("ack=1", "ack=0"), good.replace("ack=1", "ack=-1")):
            with self.subTest(log=log), self.assertRaises(ValueError):
                gate.grade_axi_activity(log)

    def test_canonical_fault_order_and_duplicates_are_preserved(self):
        first = "[FAULT] vec=7 err=00000000 pc=00401fff state=2 v86=0 depth=0\n"
        second = "[FAULT] vec=14 err=00000004 pc=00401fff state=41 v86=0 depth=0\n"
        self.assertEqual(gate.checks.fault_records(first + second),
                         ([(7, 0, 0x401fff), (14, 4, 0x401fff)], [2, 41]))
        self.assertEqual(gate.checks.fault_records(first + first)[0],
                         [(7, 0, 0x401fff), (7, 0, 0x401fff)])

    def test_malformed_fault_stdout_is_never_ignored(self):
        for text in ("[FAULT] truncated", "tb: [FAULT] vec=0x00", "noise [FAULT] trailing"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                gate.checks.fault_records(text)


if __name__ == "__main__":
    unittest.main()
