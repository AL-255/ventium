"""Keep corner stimulus external and preserve the native resource supervisor."""
import unittest

import run_qualified_pair_credit_corners as corners


class Corners(unittest.TestCase):
    def test_public_pins_and_existing_scoreboard(self):
        text = corners.fixture()+corners.leaf()
        self.assertNotRegex(text, r'(?m)^\s*(force|release)\s')
        self.assertIn('.shutdown(shutdown)', text)
        self.assertIn(".m_axi_bresp(inject_b_error ? 2'b10 : bresp)", text)
        self.assertIn('slv.mem[a]!==expected_mem[a]', text)
        for witness in ('quad_release!=1', 'split_release!=1', 'deny_release!=1',
                        'error_release!=1', 'shutdown_checks!=1'):
            self.assertIn(witness, text)

    def test_supervisor_limits_and_strict_errors_retained(self):
        text = corners.derive()
        compile(text, corners.__file__, 'exec')
        for guard in ('free>5*1024**3', 'free>4*1024**3', 'pass_fds=(9,)',
                      'timeout=180', 'timeout=30', "'-j','32'", "'UNOPTFLAT'",
                      'pins_unchanged=all', "'UNOPTFLAT'"):
            # Guard names below are checked without executing any build.
            self.assertIn(guard, text)
        self.assertIn("result['rows'][0]['coverage']==result['rows'][1]['coverage']", text)
        self.assertIn("['AXI_BFM_MON','VEN_AXI_RESP_FAULT_INJECT']", text)


if __name__ == '__main__':
    unittest.main()
