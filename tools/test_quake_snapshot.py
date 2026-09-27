#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Focused regression checks for post-init snapshot memory discovery.

Run with: python3 tools/test_quake_snapshot.py
"""
import unittest

import quake_snapshot as qs


class FakeRSP:
    """Minimal read-only GDB memory stub for scan_regions tests."""

    def __init__(self, ranges):
        self.ranges = ranges

    def read_mem(self, addr, size):
        for lo, hi, fill in self.ranges:
            if lo <= addr and addr + size <= hi:
                return bytes([fill]) * size
        return None


def flattened(regions):
    spans = sorted((int(r["vaddr"], 0), len(bytes.fromhex(r["hex"])))
                   for r in regions)
    result = []
    for lo, size in spans:
        hi = lo + size
        if result and result[-1][1] == lo:
            result[-1] = (result[-1][0], hi)
        else:
            result.append((lo, hi))
    return result


class SnapshotScanTest(unittest.TestCase):
    def test_mapping_crossing_sweep_limit_is_completed(self):
        rsp = FakeRSP([(0x3000, 0x9000, 0x5A)])
        regions = qs.scan_regions(rsp, 0x1000, 0x5000, 0x1000, 0x1000,
                                  False, scan_max=0x10000)
        self.assertEqual(flattened(regions), [(0x3000, 0x9000)])

    def test_high_pointer_anchor_is_not_lost(self):
        rsp = FakeRSP([(0x12000, 0x14000, 0xA5)])
        regions = qs.scan_regions(rsp, 0x1000, 0x10000, 0x1000, 0x1000,
                                  False, anchors=(0x12004,), scan_max=0x20000)
        self.assertEqual(flattened(regions), [(0x12000, 0x14000)])

    def test_clipped_mapping_fails_loudly(self):
        rsp = FakeRSP([(0x3000, 0xA000, 0x11)])
        with self.assertRaises(qs.gt.RSPError):
            qs.scan_regions(rsp, 0x1000, 0x5000, 0x1000, 0x1000,
                            False, scan_max=0x8000)


if __name__ == "__main__":
    unittest.main()
