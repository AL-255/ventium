"""Preparation/profile tests only; these do not run a compiler or simulator."""
import json
import os
from pathlib import Path
import unittest

import build_v_load_payload_core as build


class Preparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['V_LOAD_PAYLOAD_PARENT']).resolve(strict=True)
        cls.command = json.loads((cls.parent.parent/'build-started.json').read_text())['command']

    def test_exact_profile(self):
        self.assertEqual(len(build.profile(self.command)), 152)
        self.assertEqual(build.CHANGES, ['rtl/core/core.sv', 'rtl/core/core_gpr_wb.svh'])

    def test_profile_and_backend_drift_rejected(self):
        for before, after in (
            ('VEN_RAW_V_READ_PRIME', 'VEN_P54_DUAL_LOAD_PRIME'),
            ('VEN_P54_DUAL_BYTE_LOAD_PAIR', 'VEN_TEST_OTHER'),
            ('VEN_SYS_FASTPATH_RELOC', 'VEN_TEST_OTHER'),
            ('-GAXI_LINE_REPLAY=0', '-GAXI_LINE_REPLAY=1'),
            ('--assert', ''), ('VL_J=32', 'VL_J=1')):
            with self.subTest(before=before), self.assertRaises(AssertionError):
                build.profile([arg.replace(before, after) for arg in self.command])

    def test_proposal_retains_commit_and_merge(self):
        old = {p: (self.parent/p).read_text() for p in build.recipe.PARENTS}
        new = build.recipe.transform(old)
        wb = 'rtl/core/core_gpr_wb.svh'
        self.assertEqual(new[wb].replace(build.recipe.NEW, build.recipe.OLD), old[wb])
        self.assertEqual(new['rtl/core/core.sv'].replace(build.recipe.WITNESS, ''), old['rtl/core/core.sv'])
        self.assertIn('pipe_v_eff.dst_hi8);', new[wb])
        self.assertIn('if (pipe_pair_eff) begin', new[wb])


if __name__ == '__main__':
    unittest.main()
