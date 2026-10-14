import os
from pathlib import Path
import subprocess
import unittest

import prepare_response_kind_mux as recipe


class ResponseKindTests(unittest.TestCase):
    def source(self):
        return (Path(os.environ['RESPONSE_KIND_PARENT']) / recipe.FILE).read_text()

    def test_exact_additions_and_drift_guards(self):
        source = self.source()
        candidate = recipe.transform(source)
        self.assertEqual(candidate.replace(recipe.DECL, '').replace(recipe.MUX, ''), source)
        for changed in (source+'\n', candidate):
            with self.assertRaises(ValueError):
                recipe.transform(changed)

    def test_no_control_or_state_authority(self):
        additions = recipe.DECL + recipe.MUX
        for forbidden in ('always_ff', 'c_ack =', 'c_req =', 'rd_armed <=', 'code_access ='):
            self.assertNotIn(forbidden, additions)
        self.assertIn('(c_wstrb == early_wstrb_q)', additions)
        self.assertIn('code_payload_access ?', additions)

    def test_unconstrained_32bit_contract_and_negative_controls(self):
        for mutant, expected in ((None, 'unsat'), ('reverse_kind', 'sat'), ('lost_stream', 'sat')):
            completed = subprocess.run(['/usr/bin/z3', '-in'], input=recipe.formal(mutant),
                capture_output=True, text=True, check=True, timeout=5)
            self.assertEqual(completed.stdout.strip(), expected)
            self.assertEqual(completed.stderr, '')


if __name__ == '__main__':
    unittest.main()
