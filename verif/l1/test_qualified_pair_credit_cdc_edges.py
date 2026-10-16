"""Do not change architectural data expectations to fix a handshake test."""
import unittest

import run_qualified_pair_credit_cdc_edges as edges


class CDCEdges(unittest.TestCase):
    def test_all_three_request_tasks_wait_for_consuming_edge(self):
        before = edges.previous.fixture('cdc')
        after = edges.fixture('cdc')
        self.assertEqual(before.count('@(posedge core_clk); #1;'), 3)
        self.assertNotIn('@(posedge core_clk); #1;', after)
        for expected in ('32\'hDEAD_BEEF', '32\'hCAFE_F00D',
                         '.CORE_HALF(5), .AXI_HALF(2)', '.CORE_HALF(2), .AXI_HALF(5)',
                         '.CORE_HALF(4), .AXI_HALF(4)', '.CORE_HALF(5), .AXI_HALF(3)',
                         'if(accepted_writes!=41 || first_write_commits!=1)'):
            self.assertIn(expected, after)

    def test_driver_preserves_native_rejection_and_limits(self):
        text = edges.derive()
        compile(text, edges.__file__, 'exec')
        for expected in ('timeout=180', 'timeout=30', 'pass_fds=(9,)',
                         're.search', 'Path(previous.__file__).resolve()',
                         'diagnostic_control=True'):
            self.assertIn(expected, text)


if __name__ == '__main__':
    unittest.main()
