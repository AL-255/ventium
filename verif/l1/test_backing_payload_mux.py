"""Source-boundary and observer checks; native equivalence is a separate run."""
from pathlib import Path
import re
import unittest

import prepare_backing_payload_mux as recipe
import run_backing_payload_mux_cache as cache
import run_backing_payload_mux_leaf as leaf

SOURCE=cache.DATA/'prefix-payload-core-r1/candidate/rtl/mem/ven_l1d.sv'


class MuxTests(unittest.TestCase):
    def test_source_drift_and_double_application(self):
        old=SOURCE.read_text();new=recipe.transform(old)
        for bad in (old+'\n',new):
            with self.assertRaises(ValueError):recipe.transform(bad)

    def test_only_original_producer_replaced(self):
        old=SOURCE.read_text();new=recipe.transform(old);block=recipe.block(old)
        start=old.index(block)
        self.assertEqual(new[:start],old[:start])
        self.assertTrue(new.endswith(old[start+len(block):]))
        self.assertIn('`else\n'+block+'`endif',new)

    def test_payload_selector_has_no_late_control(self):
        code='\n'.join(s.split('//',1)[0] for s in recipe.PAYLOAD.splitlines())
        for signal in ('c_req','stream_path','c_pair_req','c_pair_ready','c_pair_intent_ready'):
            self.assertNotRegex(code,r'\b'+signal+r'\b')
        self.assertEqual(set(re.findall(r'\b(m_\w+)\s*=',code)),{'m_addr','m_wstrb'})

    def test_full_output_witness_including_idle_hints(self):
        witness=recipe.witness(SOURCE.read_text())
        for name in recipe.FIELDS:
            self.assertIn(f'assert ({name} === payload_mux_before_{name})',witness)
        self.assertIn('always_ff @(posedge clk) if (rst_n) begin',witness)
        self.assertNotIn('if (m_req',witness)

    def test_negative_fixtures_are_distinct(self):
        source=SOURCE.read_text();positive=leaf.fixture(source,'positive')
        for mode in ('late-addr','wrong-v','fill-strobe','lost-credit'):
            self.assertNotEqual(leaf.fixture(source,mode),positive)

    def test_cache_observer_does_not_mask_payload(self):
        # Minimal port inventory is sufficient to exercise observer generation.
        ports=[('output','[31:0] ','m_addr'),('output','[3:0] ','m_wstrb'),
               ('output','[31:0] ','m_wdata'),('output','[31:0] ','c_rdata')]
        text=cache.fixture(ports)
        for _,_,name in ports:self.assertIn(f'if({name}!==ref_{name})',text)
        self.assertNotIn('contract_pair_valid',text)


if __name__=='__main__':unittest.main()
