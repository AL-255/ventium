"""Check proof scope, exact source binding and fail-closed witness decoding."""
from pathlib import Path
import unittest

import prove_parallel_write_admission as proof


class Proof(unittest.TestCase):
    def test_no_environment_assumptions(self):
        for quad in (False, True):
            text = proof.symbolic(quad)
            self.assertEqual(text.count('(assert '), 1)
            self.assertIn('(assert mismatch)', text)
            self.assertIn('(declare-const ADDR_MASK (_ BitVec 32))', text)
            for name in ('m_addr','m_pair_addr','m_wstrb','m_pair_wstrb','wq_count'):
                self.assertIn('(declare-const '+name+' ', text)
            self.assertIn('(not (= (pair_ack old_enq) (pair_ack new_enq)))', text)
            self.assertIn('(not (= (ack old_enq) (ack new_enq)))', text)
            self.assertNotIn('(get-value', text)

    def test_native_fixture_source_and_mutants(self):
        path = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/'
                    'raw-prime-storage-fpga-r1/ventium/rtl/mem/ven_axi_master.sv')
        old = path.read_text()
        values = {n:0 for n in proof.WIDTHS} | {n:False for n in proof.BOOLS}
        positive = proof.fixture(old, values, 'none')
        self.assertIn(proof.recipe.enqueue(old).replace('wr_enq ', 'old_enq '), positive)
        self.assertIn("rst=1'b1;", positive)
        self.assertIn('PROOF-POSITIVE-MISMATCH', positive)
        for mode in proof.MODES:
            text = proof.fixture(old, values, mode)
            self.assertIn('PROOF-MUTANT-NOT-DETECTED', text)
            self.assertNotEqual(text, positive)
        with self.assertRaises(AssertionError): proof.fixture(old+'\n', values, 'none')

    def test_model_scope_and_mutants(self):
        original = proof.symbolic(True)
        for mode in proof.MODES:
            text = proof.symbolic(True, mode)
            self.assertNotEqual(text, original)
            self.assertIn('(get-value', text)
        self.assertIn('(assert new_enq)', proof.symbolic(False, nonvacuous=True))
        with self.assertRaises(AssertionError): proof.symbolic(True, 'unsupported')

    def test_counterexample_decode_is_complete(self):
        pairs = [(n, '#b'+'0'*w) for n,w in proof.WIDTHS.items()]
        pairs += [(n, 'true') for n in proof.BOOLS]
        output = 'sat\n('+'\n'.join(f'({n} {v})' for n,v in pairs)+')\n'
        decoded = proof.witness(output)
        self.assertEqual(len(decoded), len(proof.WIDTHS)+len(proof.BOOLS))
        self.assertTrue(decoded['m_req'])
        for bad in (output.replace('sat\n','unknown\n'), output.replace('(m_req true)',''),
                    output+'(m_req false)', output+'(unknown true)'):
            with self.assertRaises(AssertionError): proof.witness(bad)


if __name__ == '__main__': unittest.main()
