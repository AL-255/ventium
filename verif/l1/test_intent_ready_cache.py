"""Host checks of the full-profile runner; no native RTL acceptance claim."""
import ast
import unittest
from unittest.mock import patch

import run_intent_ready_cache as driver


class IntentReadyFullCache(unittest.TestCase):
    def test_exact_parent_full_profile_and_both_prior_gates(self):
        text=driver.derive();ast.parse(text)
        for marker in ("MODEL='e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'",
                       "len(defines)==152",'recipe.caller_contract',
                       "prior['pins'].items()",'paired.admit_proof(proof)',
                       'admit_pairs(args.pairs.resolve(strict=True))',
                       "assert changed==(args.pairs.resolve(strict=True)/'ven_l1d.sv').read_text()"):
            self.assertIn(marker,text)

    def test_public_corner_cases_and_entire_cache_comparisons_retained(self):
        text=driver.derive()
        for marker in ('wire c_pair_intent=c_pair_req','logic c_read_ack, c_pair_intent_ready;',
                       'miter.miter_fixture(tb,False,True)','run_fresh_pair_capture()',
                       'dut.shadow_line_q !== control.shadow_line_q',
                       'c_pair_intent_ready !== shadow_c_pair_ready',
                       'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):
            self.assertIn(marker,text)
        self.assertNotIn('compare_parent',text)

    def test_bounded_native_lifecycle_and_acceptance_limits(self):
        text=driver.derive()
        for marker in ("['pgrep','-x','vivado']",'pass_fds=(9,)',"'-j','32'",
                       'timeout=180','timeout=40','shutil.disk_usage(root).free>4*1024**3',
                       'whole_core=False','hardware_acceptance=False',
                       'standard_suite=False','gameplay_ipc=None',
                       "'IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'",
                       "miter.archive_products(folder,'tb_l1d_mem_chain')"):
            self.assertIn(marker,text)
        self.assertIn('for mutant in (False,):',text)

    def test_reject_native_lifecycle_drift(self):
        with patch.object(driver,'BASE_SHA','0'*64):
            with self.assertRaisesRegex(ValueError,'full-cache lifecycle drift'):
                driver.derive()


if __name__=='__main__':unittest.main()
