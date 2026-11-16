#!/usr/bin/env python3
"""Unit tests for Ventium Dhrystone 2.1 console parser and marginal math."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_dhrystone import compute_marginal_loop, parse_guest_console


VALID_SAMPLE = """\
VENTIUM DHRYSTONE 2.1 BARE-METAL HARNESS
DHRY-CONFIG profile=pentium_o3_noinline reg=0 warmup=20 runs=200
DHRY-STATE Int_Glob=5 Bool_Glob=1 Ch_1_Glob=A Ch_2_Glob=B Arr1_8=7 Arr2_8_7=210 Ptr_Int=17 NextPtr_Int=18
DHRY-TSC start=00000000:0001130d stop=00000000:0003acc5
DHRY-TSC delta=00000000:000299b8 runs=200
DHRY-SELFCHECK PASS
DHRY-END
"""


class TestDhrystoneParser(unittest.TestCase):
    def test_valid_console_output(self) -> None:
        res = parse_guest_console(VALID_SAMPLE, expected_runs=200, expected_warmup=20)
        self.assertTrue(res["selfcheck_pass"])
        self.assertEqual(res["delta_tsc"], 0x299B8)
        self.assertAlmostEqual(res["cycles_per_dhrystone"], 170424 / 200)
        self.assertAlmostEqual(res["dmips_per_mhz"], (1_000_000.0 / 852.12) / 1757.0)

    def test_rejects_bad_arr2_state(self) -> None:
        bad = VALID_SAMPLE.replace("Arr2_8_7=210", "Arr2_8_7=209")
        with self.assertRaises(ValueError):
            parse_guest_console(bad, expected_runs=200, expected_warmup=20)

    def test_rejects_missing_pass_marker(self) -> None:
        bad = VALID_SAMPLE.replace("DHRY-SELFCHECK PASS", "DHRY-SELFCHECK FAIL phase=measure code=0x00000006")
        with self.assertRaises(ValueError):
            parse_guest_console(bad, expected_runs=200, expected_warmup=20)

    def test_rejects_tsc_mismatch(self) -> None:
        bad = VALID_SAMPLE.replace("delta=00000000:000299b8", "delta=00000000:000299b9")
        with self.assertRaises(ValueError):
            parse_guest_console(bad, expected_runs=200, expected_warmup=20)

    def test_marginal_loop_math(self) -> None:
        low = {
            "runs": 200,
            "delta_tsc": 170424,
            "whole_run_clocks": 248258,
            "whole_run_retires_total": 175170,
            "whole_run_retires_u": 132816,
            "whole_run_retires_paired_v": 42354,
        }
        high = {
            "runs": 2200,
            "delta_tsc": 1874424,
            "whole_run_clocks": 1952516,
            "whole_run_retires_total": 1485230,
            "whole_run_retires_u": 1116861,
            "whole_run_retires_paired_v": 368369,
        }
        m = compute_marginal_loop(low, high)
        self.assertEqual(m["delta_runs"], 2000)
        self.assertEqual(m["delta_tsc"], 1704000)
        self.assertAlmostEqual(m["cycles_per_dhrystone"], 852.0)
        self.assertAlmostEqual(m["dmips_per_mhz"], (1_000_000.0 / 852.0) / 1757.0)
        self.assertAlmostEqual(m["loop_ipc_total_uv"], (1485230 - 175170) / 1704000)
        self.assertAlmostEqual(m["loop_ipc_primary_u_only"], (1116861 - 132816) / 1704000)


if __name__ == "__main__":
    unittest.main()
