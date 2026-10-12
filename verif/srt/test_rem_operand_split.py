"""Exact-source and fixture checks; native sequential verification is separate."""
from pathlib import Path
import unittest

import prepare_rem_operand_split as patch
import run_rem_operand_split as run

PARENT = Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS/payload-current-core-r1/candidate')


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.source = {name: (PARENT/name).read_text() for name in patch.HASHES}

    def test_exact_scope(self):
        after = patch.transform(self.source)
        self.assertEqual(set(after), set(self.source))
        for token in ('ST_DRUN: begin', 'ST_QRUN: begin', 'ST_RRUN: begin'):
            # The entire recurrence/rounding tail stays byte-identical.
            self.assertEqual(after['rtl/fpu/fpu_srt_div.sv'].split(token, 1)[1],
                             self.source['rtl/fpu/fpu_srt_div.sv'].split(token, 1)[1])
        top = after['fp_shared/ven_fp_top.sv']
        self.assertEqual(top[top.index('`ifdef VEN_SRT_PAYLOAD_SELECT'):top.index('`ifdef '+patch.FLAG, top.index('`ifdef VEN_SRT_PAYLOAD_SELECT'))],
                         self.source['fp_shared/ven_fp_top.sv'][self.source['fp_shared/ven_fp_top.sv'].index('`ifdef VEN_SRT_PAYLOAD_SELECT'):self.source['fp_shared/ven_fp_top.sv'].index('  // All architectural mutation')])
        self.assertIn('.rem_a(st0_data)', top)
        self.assertIn('.rem_b(sti_data)', top)

    def test_drift_and_reapplication_rejected(self):
        after = patch.transform(self.source)
        for name in patch.HASHES:
            wrong = dict(self.source); wrong[name] += '\n'
            with self.assertRaisesRegex(ValueError, 'drift'):
                patch.transform(wrong)
        with self.assertRaisesRegex(ValueError, 'reapplication'):
            patch.transform(after)
        with self.assertRaisesRegex(ValueError, 'both'):
            patch.transform({})

    def test_fixture_preserves_checks_and_challenges_unused_ports(self):
        before = Path(__file__).with_name('tb_input_norm_miter.sv').read_text()
        off, on = (run.fixture(before, enabled) for enabled in (False, True))
        self.assertNotIn('.rem_a(', off)
        self.assertIn('.a(mode==2 ? ~a : a)', on)
        self.assertIn('.rem_a(mode==2 ? a : ~a)', on)
        for text in (off, on):
            for token in ('SRT_INPUT_CONTROL_MISMATCH', 'SRT_INPUT_PHASE_MISMATCH',
                          'SRT_INPUT_RESULT_MISMATCH', 'SRT_INPUT_STATE_MISMATCH',
                          'samples!=4736', 'resets!=24', 'checks<50000'):
                self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
