"""Scope/recipe checks; native admission/cache tests are separate evidence."""
import os
from pathlib import Path
import unittest

import prepare_parallel_write_admission as recipe
import run_parallel_write_admission as gate


class ParallelWriteAdmission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        mem = Path(os.environ['PARALLEL_WRITE_PARENT_MEM']).resolve(strict=True)
        cls.old = {name:(mem/name).read_text() for name in recipe.PINS}
        cls.new = recipe.transform(cls.old)

    def test_source_drift_and_reapplication_rejected(self):
        for name in recipe.PINS:
            with self.assertRaises(ValueError):
                recipe.transform(dict(self.old,**{name:self.old[name]+'\n'}))
        with self.assertRaises(ValueError): recipe.transform(self.new)

    def test_no_payload_cache_or_sequential_state_changes(self):
        self.assertEqual(self.new['ven_l1d.sv'],self.old['ven_l1d.sv'])
        old,new = self.old['ven_axi_master.sv'],self.new['ven_axi_master.sv']
        stripped = recipe.once(new,recipe.admission(recipe.enqueue(old)),recipe.enqueue(old))
        stripped = recipe.once(stripped,
            "    // Timing experiment; generic admission semantics, no caller assumption.\n"
            "    parameter bit          PARALLEL_WRITE_ADMISSION = 1'b0,\n",'')
        self.assertEqual(stripped,old)

    def test_generic_default_and_live_equivalence_assertion(self):
        text = self.new['ven_axi_master.sv']
        self.assertIn("PARALLEL_WRITE_ADMISSION = 1'b0",text)
        self.assertIn('g_original_write\n'+recipe.enqueue(self.old['ven_axi_master.sv']),text)
        self.assertIn('assert (wr_enq === original_enq)',text)
        self.assertNotIn('PAIR_REQ_CREDIT_QUALIFIED',text)

    def test_predicates_independent_of_late_controls(self):
        text = recipe.admission(recipe.enqueue(self.old['ven_axi_master.sv']))
        body = text[text.index('    logic [31:0]'):text.index('    assign wr_enq')]
        # Names in comments are harmless; check only expressions.
        import re
        expressions = '\n'.join(re.findall(r'assign\s+.*?;',body,re.S))
        self.assertNotRegex(expressions,r'\b(m_req|m_we|m_pair_req|alias_bad)\b')
        self.assertIn('!pair_write_alias_bad',expressions)
        self.assertIn('wr_can_pair',expressions)
        self.assertIn('(* keep = "true" *) logic single_admit, pair_admit;',body)

    def test_wrapper_scope_only(self):
        block = '''`ifdef VEN_P54_DUAL_STORE_PAIR
`ifndef VEN_AXI_CDC
      .PARALLEL_WRITE_ADMISSION (!EN_L2),
`endif
`endif
'''
        self.assertEqual(self.new['ventium_l1_axi.sv'].replace(block,''),self.old['ventium_l1_axi.sv'])

    def test_native_control_cases_have_no_assumption(self):
        old = self.old['ven_axi_master.sv']
        text = gate.control_fixture(old)
        self.assertIn('total!=16384',text)
        self.assertNotIn('contract_ok',text)
        self.assertIn('excluded=0',text)
        for mode in ('u_alias','v_alias','fatal','credit','request','pair_credit'):
            self.assertNotEqual(text,gate.control_fixture(old,mode))

    def test_fault_fixture_keeps_uncredited_pairs_opted_in(self):
        old = (gate.HERE/'tb_axi_quad_pair.sv').read_text()
        text = gate.fault_fixture(old,True)
        self.assertIn(".PARALLEL_WRITE_ADMISSION(1'b1)",text)
        self.assertIn('VEN_AXI_QUAD_SPLIT_TEST',text)
        self.assertNotIn('PAIR_REQ_CREDIT_QUALIFIED',text)

    def test_cache_fixture_retains_both_masters_and_complete_state(self):
        text = gate.cache_fixture()
        self.assertEqual(text.count(".PARALLEL_WRITE_ADMISSION(1'b1)"),1)
        for item in ('dc_tag_way0[s]','dc_tag_way1[s]','dc_val[s][w]',
                     'g_compare_all_data','data[row]','dc_lru[s]',
                     'BACKING-AXI-MISMATCH state wq_count'):
            self.assertIn(item,text)
        self.assertNotIn('force ',text)


if __name__ == '__main__': unittest.main()
