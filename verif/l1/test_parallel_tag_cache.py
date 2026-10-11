"""Check fixture construction before compiling the full L1 sequential miter."""
import difflib
from pathlib import Path
import unittest
from run_parallel_tag_cache import BASE_OUTPUTS, STREAM_OUTPUTS, miter_fixture


class FixtureConstruction(unittest.TestCase):
    def test_original_stimuli_remain_verbatim(self):
        for stream in (False, True):
            path = Path(__file__).with_name('tb_l1d_' + ('window_keep_reset' if stream else 'mem_chain') + '.sv')
            original = path.read_text()
            for flat in (False, True):
                with self.subTest(stream=stream, flat=flat):
                    candidate = miter_fixture(original, stream, flat)
                    edits = [r for r in difflib.SequenceMatcher(None, original.splitlines(), candidate.splitlines(), autojunk=False).get_opcodes() if r[0] != 'equal']
                    self.assertEqual(len(edits), 1)
                    self.assertEqual(edits[0][0], 'insert')
                    self.assertEqual(candidate.count('control_l1d control('), 1)
                    outputs = BASE_OUTPUTS | (STREAM_OUTPUTS if stream else {})
                    for name in outputs:
                        self.assertEqual(candidate.count(f'.{name}(shadow_{name})'), 1)
                        self.assertIn(f'dut.{name} !== shadow_{name}', candidate)
                    self.assertIn('bank<8', candidate)
                    self.assertIn('row<256', candidate)
                    self.assertIn('s<128', candidate)
                    self.assertIn('w<2', candidate)
                    self.assertIn('dc_tag[s*2+w]' if flat else 'dc_tag[s][w]', candidate)

    def test_fixture_drift_rejected(self):
        original = Path(__file__).with_name('tb_l1d_mem_chain.sv').read_text()
        variants = [original.replace('ven_l1d dut', 'ven_l1d renamed'),
            original.replace('ven_l1d dut(.*);', 'ven_l1d dut(.c_ack(c_ack), .*);'),
            original + '\nven_l1d dut(.*);\n',
            miter_fixture(original, False, False)]
        for candidate in variants:
            with self.subTest(length=len(candidate)), self.assertRaises(ValueError):
                miter_fixture(candidate, False, False)


if __name__ == '__main__':
    unittest.main()
