import unittest
import prepare_response_payload as p


class RecipeTests(unittest.TestCase):
    def source(self):
        return '\n'.join((p.OLD, '  // golden / "L1-useless" mode:',
            '  assign rd_match  = rd_armed && !stream_path && (rd_addr_q == c_addr)',
            '      assert (c_rdata === payload_before_cut)',
            '  always_ff @(posedge clk) begin /* sentinel */ end'))

    def test_exact_reversible_payload_only(self):
        source = self.source()
        changed = p.transform(source)
        block = '`ifdef '+p.FLAG+'\n'+p.OLD.replace('shadow_reuse ?', 'shadow_payload_select ?')+\
            '\n`else\n'+p.OLD+'\n`endif'
        self.assertEqual(changed.replace(block,p.OLD).replace(p.DECL+'\n',''),source)
        self.assertEqual(changed.count('always_ff @(posedge clk) begin /* sentinel */ end'),1)
        self.assertEqual(changed.count('assert (c_rdata === payload_before_cut)'),1)
        self.assertIn('RESPONSE-PAYLOAD-DUPLICATE',changed)

    def test_no_lookahead_or_tag_in_new_selector(self):
        select = p.DECL.split('wire shadow_payload_select = ',1)[1].split(';',1)[0]
        for name in ('hit', 'mc_', 'c_next', 'c_ack'):
            self.assertNotIn(name, select)
        for name in ('rd_match', 'shadow_valid_q', 'shadow_line_addr_q'):
            self.assertIn(name, select)

    def test_missing_and_duplicate_contract_rejected(self):
        for anchor in (p.OLD, '  // golden / "L1-useless" mode:',
                       '      assert (c_rdata === payload_before_cut)'):
            with self.subTest(anchor=anchor):
                with self.assertRaises(ValueError): p.transform(self.source().replace(anchor,''))
                with self.assertRaises(ValueError): p.transform(self.source()+'\n'+anchor)

    def test_repeated_application_rejected(self):
        with self.assertRaises(ValueError): p.transform(p.transform(self.source()))


if __name__=='__main__':
    unittest.main()
