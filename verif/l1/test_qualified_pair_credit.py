"""Source-preservation and scope tests; not a replacement for native gates."""
import os
from pathlib import Path
import unittest

import prepare_qualified_pair_credit as recipe
import run_qualified_pair_credit_cache as cache
import run_qualified_pair_credit_leaf as leaf


class QualifiedPairCredit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(os.environ['PAIR_CREDIT_PARENT_MEM']).resolve(strict=True)
        cls.old = {name:(root/name).read_text() for name in recipe.PINS}
        cls.new = recipe.transform(cls.old)

    def test_all_three_source_pins_and_reapplication(self):
        for name in self.old:
            with self.assertRaises(ValueError):
                recipe.transform(dict(self.old, **{name:self.old[name]+'\n'}))
        with self.assertRaises(ValueError): recipe.transform(self.new)

    def test_no_cache_state_or_request_change(self):
        self.assertEqual(self.old['ven_l1d.sv'], self.new['ven_l1d.sv'])
        old, new = self.old['ven_axi_master.sv'], self.new['ven_axi_master.sv']
        # Entire downstream state machine, queue updates, burst/error/reset
        # handling and output packet equations remain byte-identical.
        marker = '  assign wr_quad_enq ='
        self.assertEqual(old[old.index(marker):], new[new.index(marker):])
        before = new[:new.index('  generate if (PAIR_REQ_CREDIT_QUALIFIED)')]
        start = before.index('    // Opt-in contract:')
        stop = before.index('    // #34:', start)
        before = before[:start]+before[stop:]
        self.assertEqual(before, old[:old.index('  assign wr_enq      =')])

    def test_generic_branch_verbatim_and_default_off(self):
        new = self.new['ven_axi_master.sv']
        self.assertIn("parameter bit          PAIR_REQ_CREDIT_QUALIFIED = 1'b0,", new)
        self.assertIn('  end else begin : g_pair_credit_unqualified\n'+recipe.enqueue(self.old['ven_axi_master.sv']), new)
        self.assertIn('assert (!(m_req && m_we && m_pair_req) || m_pair_ready)', new)
        self.assertIn('assert (wr_enq === wr_enq_unqualified)', new)

    def test_wrapper_only_direct_qualified_path(self):
        block = '''`ifdef VEN_P54_DUAL_STORE_PAIR
`ifndef VEN_AXI_CDC
      // No clock crossing or intervening L2 may weaken this live-credit contract.
      .PAIR_REQ_CREDIT_QUALIFIED (!EN_L2),
`endif
`endif
'''
        self.assertEqual(self.new['ventium_l1_axi.sv'].replace(block, ''), self.old['ventium_l1_axi.sv'])

    def test_native_equation_extraction_preserves_both_quad_arms(self):
        text = leaf.fixture(self.old['ven_axi_master.sv'], self.new['ven_axi_master.sv'], True, 'positive')
        self.assertEqual(text.count('`ifdef'), text.count('`endif'))
        self.assertIn('total!=8192', text)
        self.assertIn('contract_ok || !PAIR_REQ_CREDIT_QUALIFIED', text)
        self.assertIn('new_enq,new_ack,new_pair_ack', text)
        for mode in ('fatal','alias','credit','unqualified'):
            self.assertNotEqual(text, leaf.fixture(self.old['ven_axi_master.sv'], self.new['ven_axi_master.sv'], True, mode))

    def test_real_cache_miter_keeps_complete_arrays(self):
        text = cache.fixture()
        self.assertEqual(text.count(".PAIR_REQ_CREDIT_QUALIFIED(1'b1)"), 1)
        for item in ('dc_tag_way0[s]', 'dc_tag_way1[s]', 'dc_val[s][w]',
                     'g_compare_all_data', 'data[row]', 'dc_lru[s]',
                     'BACKING-AXI-MISMATCH state wq_count', 'c_pair_intent=c_pair_req'):
            self.assertIn(item, text)
        self.assertNotIn('force ', text)


if __name__ == '__main__': unittest.main()
