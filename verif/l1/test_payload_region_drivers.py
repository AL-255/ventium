"""Guard/pinning/matrix admission tests, separate from native RTL results."""
import ast
import unittest
from unittest.mock import patch

import build_payload_region_core as build
import run_payload_region_cache as cache


class RegionDrivers(unittest.TestCase):
    def test_cache_lifecycle_and_full_geometry_retained(self):
        text=cache.derive(); ast.parse(text)
        for marker in ('admit_leaf(proof)','len(defines)==152',
                       'miter.miter_fixture(tb,False,True)','run_fresh_pair_capture()',
                       'dut.shadow_line_q !== control.shadow_line_q',
                       'c_pair_intent_ready=1',"'IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'",
                       "'-j','32'",'pass_fds=(9,)','timeout=180','timeout=40',
                       "['pgrep','-x','vivado']",'whole_core=False','standard_suite=False',
                       'hardware_acceptance=False','gameplay_ipc=None'):
            self.assertIn(marker,text)

    def test_core_native_build_unchanged_private_host(self):
        text=build.derive(); ast.parse(text)
        old=(build.HERE/'build_fp_high_valid_core.py').read_text()
        self.assertEqual(text[text.index('def build(root):'):text.index('def main():')],
                         old[old.index('def build(root):'):old.index('def main():')])
        for marker in ("host=root/('tb_payload_region_'",'len(files)==195',
                       'len(definitions)==len(set(definitions))==152',
                       'PARALLEL-CACHE-MITER checks=747037 next=463',
                       "['rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv']",'recipe.CACHEMAP',
                       "changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()",
                       'canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False'):
            self.assertIn(marker,text)

    def test_reject_lifecycle_drift(self):
        for driver in (build,cache):
            with patch.object(driver,'BASE_SHA','0'*64):
                with self.assertRaises(ValueError): driver.derive()


if __name__=='__main__': unittest.main()
