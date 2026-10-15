"""Check fixed-owner synthesis observation and single read-only continuation."""
import ast
import unittest

import run_v_result_carry_timing_sequence as p


class Sequence(unittest.TestCase):
    def test_current_identities_and_exact_synthesis_owner(self):
        invocation = 'a5b21d4ee38a4193989de23ecfd21c61'
        text = p.derive(invocation)
        ast.parse(text)
        self.assertIn("SYNTH_INVOCATION = '"+invocation+"'", text)
        self.assertIn('ventium-v-result-carry-synth-oct15-r3.service', text)
        self.assertIn('v-result-carry-synthesis-r3/audit_closed.py', text)
        self.assertIn('v-result-carry-clock-prepared-r1.json', text)
        self.assertNotIn('v-result-carry-synthesis-r1/', text)
        self.assertIn("state['InvocationID'] == invocation", text)
        self.assertIn("state['SubState'] == 'exited'", text)
        self.assertIn("state['ExecMainStatus'] == '0'", text)

    def test_no_retry_or_implementation_launch(self):
        text = p.derive('a5b21d4ee38a4193989de23ecfd21c61')
        self.assertEqual(text.count("['systemd-run'"), 1)
        self.assertIn("'--unit='+CLOCK", text)
        self.assertNotIn("'--unit='+SYNTH", text)
        self.assertIn('clock owner already exists; refuse duplicate', text)
        self.assertIn('no_synthesis_or_implementation_launch=True', text)
        self.assertLess(text.index("str(ROOT/'v-result-carry-synthesis-r3/audit_closed.py')"),
                        text.index("['systemd-run'"))

    def test_invalid_invocation_rejected(self):
        for value in ('', 'latest', 'a'*31, 'x'*32):
            with self.assertRaises(ValueError):
                p.derive(value)


if __name__ == '__main__':
    unittest.main()
