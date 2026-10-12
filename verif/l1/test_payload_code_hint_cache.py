"""Fixture/launch-contract tests only; no compiler or FPGA process is launched."""
from pathlib import Path
import unittest

import run_payload_code_hint_cache as driver


FIXTURE = '''module tb_l1d_mem_chain;
  ven_l1d dut(.*);
  initial begin
    run_code_payload();
    $finish;
  end
  always @(posedge clk) begin
    $fdisplay(observations,"old",
      m_pair_req, m_pair_req ? m_pair_wdata : 32'd0);
  end
endmodule
'''


class FixtureContract(unittest.TestCase):
    def test_denied_request_does_not_requalify_the_code_port(self):
        text = driver.adapt_fixture(FIXTURE)
        self.assertIn('wire admitted_req = c_req && !(|hint_deny);', text)
        self.assertIn('wire qualified_code = c_req && c_code;', text)
        self.assertNotIn('wire qualified_code = admitted_req', text)
        self.assertIn('.c_req(admitted_req), .c_code(qualified_code), .*', text)

    def test_original_corpus_and_one_ordered_observer_retained(self):
        text = driver.adapt_fixture(FIXTURE)
        self.assertEqual(text.count('run_code_payload();'), 1)
        self.assertEqual(text.count('    run_payload_hint_denied();'), 1)
        self.assertEqual(text.count('always @(posedge clk)'), 1)
        self.assertIn('pair_rsp_owner, pair_rsp_paddr, m_rd_narrow, m_rd_size', text)
        self.assertIn('if(hint_denied_cases!=32 || hint_idle_cases!=32)', text)

    def test_source_drift_and_duplicate_anchor_rejected(self):
        with self.assertRaises(ValueError):
            driver.adapt_fixture(FIXTURE.replace('ven_l1d dut(.*);', 'ven_l1d renamed(.*);'))
        with self.assertRaises(ValueError):
            driver.adapt_fixture(FIXTURE+FIXTURE)

    def test_guard_profile_matches_repository_contract(self):
        guard = (driver.REPO/'tools/build_scope.sh').read_text()
        source = Path(driver.__file__).read_text()
        self.assertIn('ipc_parallel32)', guard)
        self.assertIn("os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'", source)
        self.assertIn("os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'", source)
        self.assertIn("['pgrep', '-x', 'vivado']", source)
        self.assertIn("'--assert', '-j', '32'", source)
        self.assertIn('pass_fds=(9,)', source)


if __name__ == '__main__':
    unittest.main()
