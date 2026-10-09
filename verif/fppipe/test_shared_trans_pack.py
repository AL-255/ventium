"""Fail closed on source drift; selection changes may not rewrite arithmetic."""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('proposal', HERE/'prepare-shared-trans-pack.py')
proposal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proposal)


class TransformContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = (HERE.parents[1]/'fp_shared/ven_fp_trans.sv').read_text()
        cls.candidate = proposal.prepare(cls.original)

    def test_arithmetic_functions_identical(self):
        functions = lambda text: re.findall(r'  function automatic .*?  endfunction', text, re.S)
        self.assertEqual(functions(self.original), functions(self.candidate))

    def test_exact_consumers(self):
        self.assertEqual(self.candidate.count('normalize_round_pack('), 2)
        self.assertEqual(self.candidate.count('<= shared_pack_result;'), 5)
        self.assertEqual(self.candidate.count('x_times_eight = shared_pack_result;'), 1)
        self.assertEqual(self.original.count('normalize_round_pack('), 7)

    def test_no_sequential_change_besides_six_calls(self):
        # The earlier always_ff blocks are table reads; the sequencer starts
        # after busy and contains all six consumers (no function definitions).
        sequencer = lambda text: text[text.index('  always_ff @(posedge clk) begin',
            text.index('  assign busy = (state != T_IDLE);')):]
        a, b = sequencer(self.original), sequencer(self.candidate)
        a = re.sub(r'normalize_round_pack\([^;]+\)', 'shared_pack_result', a)
        self.assertEqual(a, b)

    def test_reapplication_refuses(self):
        with self.assertRaises(ValueError): proposal.prepare(self.candidate)

    def test_missing_anchor_refuses(self):
        with self.assertRaises(ValueError):
            proposal.prepare(self.original.replace('f2_sig1_q | 64\'d1,', 'f2_sig1_q,'))

    def test_duplicate_anchor_refuses(self):
        with self.assertRaises(ValueError):
            proposal.prepare(self.original+'\n  assign busy = (state != T_IDLE);\n')


if __name__ == '__main__':
    unittest.main()
