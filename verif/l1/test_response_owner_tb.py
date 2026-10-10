from pathlib import Path
import unittest
import prepare_response_owner_tb as p


class OwnerFixtureTests(unittest.TestCase):
    def source(self):
        return (Path(__file__).parent/'tb_l1d_early_retarget.sv').read_text()

    def test_reversible_fixture_extension(self):
        source=self.source();changed=p.transform(source)
        self.assertEqual(changed.replace(p.EXTRA,'').replace(
            '  initial begin : owner_scenario\n    hold_b =', '  initial begin\n    hold_b ='),source)
        self.assertIn('$finish;\n      disable owner_scenario;',changed)

    def test_both_real_handshakes_check_data(self):
        self.assertEqual(p.EXTRA.count('c_ack && c_rdata == backing_word(A)'),2)
        self.assertIn('dut.early_addr_q == B && !dut.early_match',p.EXTRA)
        self.assertIn('c_req=0;',p.EXTRA)
        self.assertIn('c_req=1; c_addr=A;',p.EXTRA)

    def test_repeat_missing_or_duplicate_rejected(self):
        for text in (p.transform(self.source()),self.source().replace(p.ANCHOR,''),
                     self.source()+'\n'+p.ANCHOR):
            with self.assertRaises(ValueError):p.transform(text)


if __name__=='__main__':
    unittest.main()
