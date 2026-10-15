"""Keep the fresh runner and independent audit bound to the same model."""
import unittest

import run_backing_payload_mux_func as runner
import audit_backing_payload_mux_func as audit
import test_fetch_pair_next_func as previous_tests


class Binding(previous_tests.FreshFunctional):
    def test_native_runner(self):
        text = runner.derive()
        self.assertIn(runner.MODEL, text)
        self.assertNotIn(runner.prior.MODEL, text)
        self.assertIn("TB_EXTRA_FLAGS='--cycle-func --l1-axi'", text)
        self.assertIn('fresh_qemu=True,authenticated_input_replay=False', text)
        self.assertIn('canonical_gate_passed=False', text)

    def test_regrade_identity_and_policy(self):
        text = audit.derive()
        self.assertIn('import run_backing_payload_mux_func as runner', text)
        self.assertIn("ROOT/'backing-payload-mux-core-r1'", text)
        self.assertIn("ROOT/'backing-payload-mux-freshfunc-r1'", text)
        self.assertIn('ventium-backing-payload-mux-freshfunc-oct15-r1.service', text)
        self.assertIn('count==80800 and paired==30132', text)
        self.assertIn("['tx_regform','tx_regform2','tx_stack']", text)
        self.assertIn('same_elf_except_gcc_file_symbol', text)


if __name__ == '__main__':
    unittest.main()
