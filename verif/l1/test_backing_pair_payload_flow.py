"""Admission/plan checks; these do not replace native tests or launch a run."""
from pathlib import Path
import re
import sys
import unittest

import build_backing_pair_payload_core as build
import run_backing_pair_payload_regressions as regressions
import run_fp_high_valid_regressions as previous

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'fpga'))
import build_backing_pair_payload_soc as pc


class FlowTests(unittest.TestCase):
    def test_unchanged_full_regression_plan(self):
        args=tuple(map(Path,('/parent','/candidate','/output')))
        self.assertEqual(regressions.plan(*args),previous.plan(*args))
        self.assertEqual(len(regressions.plan(*args)),12)

    def test_models_are_the_actual_parent_and_candidate(self):
        self.assertEqual(regressions.PARENT_MODEL,build.MODEL)
        self.assertEqual(regressions.MODEL,pc.CORE_MODEL)
        self.assertEqual(pc.PARENT_MODEL,'07b59e2059a985764fe7bc9ce99ebde0530acf96e8d6dfed1e83258db1178541')
        self.assertNotEqual(regressions.PARENT_MODEL,regressions.MODEL)

    def test_exact_two_file_transfer(self):
        self.assertEqual(pc.CHANGES,sorted([build.TARGET,build.DMA]))
        self.assertEqual(set(build.recipe.PARENTS),set(pc.CHANGES))
        self.assertEqual(build.recipe.PARENTS[build.DMA],build.dma_recipe.PARENT)

    def test_recipe_rejects_drift_and_extra_files(self):
        for name in (build.TARGET,build.DMA,'rtl/core/core.sv'):
            with self.assertRaises(ValueError):build.recipe.transform('changed',name)

    def test_bounded_profile_and_native_header_checks_retained(self):
        source=build.text
        self.assertIn("os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'",source)
        self.assertIn("pass_fds=(9,)",source)
        self.assertIn("header.resolve()==(obj/'Vventium_top___024root.h').resolve()",source)
        early='\n'.join(line.split('//',1)[0] for line in build.payload_recipe.EARLY.splitlines())
        self.assertEqual(set(re.findall(r'\b(m_\w+)\s*=',early)),{'m_addr','m_wstrb'})
        self.assertNotIn('c_req',early)
        self.assertNotIn('c_pair_ready',early)
        self.assertNotIn('read_ack_absorption',source)


if __name__=='__main__':unittest.main()
