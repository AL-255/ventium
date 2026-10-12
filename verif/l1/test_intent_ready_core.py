"""Host contracts for the pending native core build, not an RTL test result."""
import ast
import unittest
from unittest.mock import patch

import build_intent_ready_core as driver
import run_intent_ready_cache as cache


class IntentReadyCoreBuild(unittest.TestCase):
    def test_exact_parent_and_two_file_delta(self):
        self.assertEqual(cache.MODEL,'e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81')
        text=driver.derive();ast.parse(text)
        for marker in ("len(files)==195",'recipe.caller_contract',
                       "['rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv']",
                       'sorted(recipe.PARENTS)','len(definitions)==len(set(definitions))==152',
                       "changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()",
                       "'VEN_SYS_FASTPATH_RELOC'","'VEN_RAW_V_READ_PRIME'"):
            self.assertIn(marker,text)

    def test_native_build_and_harness_audit_unchanged(self):
        original=(driver.HERE/'build_fp_high_valid_core.py').read_text()
        text=driver.derive()
        start,end='def build(root):','def main():'
        self.assertEqual(text[text.index(start):text.index(end)],
                         original[original.index(start):original.index(end)])
        self.assertIn("host=root/('tb_intent_ready_'",text)
        self.assertIn("HERE/'build_fp_high_valid_core.py'",text)

    def test_native_cache_required_without_inheriting_acceptance(self):
        text=driver.derive()
        for marker in ('==[(False,0,0)]','checked[\'passed\']',"checked['pins_unchanged']",
                       'PARALLEL-CACHE-MITER checks=747037 next=463',
                       "assert not checked['hardware_acceptance']",
                       'canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False',
                       'gameplay_ipc=None'):
            self.assertIn(marker,text)

    def test_reject_native_lifecycle_drift(self):
        with patch.object(driver,'BASE_SHA','0'*64):
            with self.assertRaisesRegex(ValueError,'core build lifecycle drift'):
                driver.derive()


if __name__=='__main__':unittest.main()
