"""Reject stale sources, profile changes and unrelated hardware deltas."""
import ast
import unittest
from unittest.mock import patch

import test_freeze_sfetch_boundary_rk_candidate as previous
import freeze_next_ready_rk_candidate as export

ROOT = export.builder.leaf.ROOT


class Freeze(previous.Freeze):
    def setUp(self):
        self.parent = ROOT/'sfetch-boundary-fpga-r1'
        self.sim = ROOT/'next-ready-soc-r1'
        self.old = export.builder.load(self.parent/'input-manifest.json')
        self.start = export.builder.load(self.sim/'build-started.json')
        self.closed = export.builder.load(self.sim/'build-closed.json')
        self.defs = (self.sim/'defines.txt').read_text().splitlines()

    def test_actual_profile(self):
        export.check_profile(self.old, self.start, self.closed, self.defs, export.MODEL)
        ast.parse(export.freeze_source())

    def test_stale_failed_or_reconfigured_rejected(self):
        with patch.object(previous, 'export', export):
            super().test_stale_failed_or_reconfigured_rejected()

    def test_only_exact_two_file_delta(self):
        # Reuse every rejection/source check; restore module globals afterward
        # so discovering this test cannot change the predecessor's own tests.
        with patch.object(previous, 'export', export):
            super().test_only_exact_two_file_delta()


if __name__ == '__main__': unittest.main()
