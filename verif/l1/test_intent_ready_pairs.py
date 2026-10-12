"""Host-only scope checks; native cache executions are a separate requirement."""
import ast
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import run_intent_ready_pairs as driver


class IntentReadyPairs(unittest.TestCase):
    def test_both_tag_organizations_keep_full_comparison(self):
        for flat in (False,True):
            text=driver.fixture(flat)
            self.assertEqual(text.count('.c_pair_intent(c_pair_req || explicit_intent)'),2)
            self.assertEqual(text.count('.c_pair_intent_ready(intent_only_ready)'),1)
            self.assertEqual(text.count('.L1_SETS(128)'),2)
            self.assertNotIn('compare_parent',text)
            for marker in ('g_compare_all_data','PARALLEL-PAIR-MISMATCH valid',
                           'PARALLEL-PAIR-MISMATCH lru','PARALLEL-PAIR-MISMATCH tag',
                           'INTENT-READY-MITER: shadow state','unqualified fast readiness',
                           'intent overrode backing backpressure or blocked U'):
                self.assertIn(marker,text)

    def test_native_guard_and_mutations_retained(self):
        _,text=driver.derive();ast.parse(text)
        for marker in ("pass_fds=(9,)","['pgrep','-x','vivado']",'shutil.disk_usage(root).free > 4*1024**3',
                       "'-j','32'","for w in range(3)","(True,2,'lookup')","(True,2,'credit')",
                       "recipe.caller_contract",'proof_pins.items()',"child.returncode != 0",
                       "'IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'"):
            self.assertIn(marker,text)

    def test_all_original_old_port_comparisons_remain(self):
        base=driver.pair.fixture((driver.HERE/'tb_l1d_pair_store.sv').read_text(),True)
        candidate=driver.fixture(True)
        for line in base.splitlines():
            if '$fatal(1,"PARALLEL-PAIR-MISMATCH' in line:
                self.assertIn(line,candidate)

    def test_refuse_changed_native_lifecycle(self):
        with patch.object(driver, 'LIFECYCLE_SHA256', '0'*64):
            with self.assertRaisesRegex(ValueError, 'native lifecycle drift'):
                driver.derive()

    def test_closed_leaf_proof_reaudit(self):
        root=Path(os.environ['INTENT_READY_PROOF']).resolve(strict=True)
        pins=driver.admit_proof(root)
        self.assertGreaterEqual(len(pins),57)
        self.assertIn(str(root/'qualified-ready.smt2'),pins)
        self.assertIn(str(root/'unsafe-global-replacement.stdout'),pins)

    def test_symbolic_transcript_drift_rejected(self):
        root=Path(os.environ['INTENT_READY_PROOF']).resolve(strict=True)
        original=Path.read_text
        def read(path,*args,**kwargs):
            if path==root/'qualified-ready.stdout':return 'sat\n'
            return original(path,*args,**kwargs)
        with patch.object(Path,'read_text',read):
            with self.assertRaises(AssertionError):driver.admit_proof(root)


if __name__=='__main__':unittest.main()
