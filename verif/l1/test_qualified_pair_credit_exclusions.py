"""Check that legacy traffic, checks and CDC clock ratios are not rewritten."""
import unittest

import run_qualified_pair_credit_exclusions as exclusions


class Exclusions(unittest.TestCase):
    def test_only_observer_and_top_name_differ(self):
        for profile, (top, _) in exclusions.PROFILES.items():
            source = (exclusions.HERE/(top+'.sv')).read_text()
            new = exclusions.fixture(profile)
            start = new.index('\n`ifdef PAIR_CREDIT_CANDIDATE_OBSERVE')
            end = new.index('`endif\n', start)+len('`endif\n')
            self.assertEqual(new[:start]+new[end:], source.replace('module '+top+';', 'module tb_qualified_pair_wrapper;'))
            self.assertIn("dut.u_axi.PAIR_REQ_CREDIT_QUALIFIED !== 1'b0", new)

    def test_supervisor_and_non_acceptance(self):
        text = exclusions.derive()
        compile(text, exclusions.__file__, 'exec')
        for value in ('diagnostic_control=True', 'standard_suite=False',
                      'hardware_acceptance=False', 'free>5*1024**3', 'timeout=30',
                      'pass_fds=(9,)', "'UNOPTFLAT'", "'VEN_AXI_CDC'"):
            self.assertIn(value, text)


if __name__ == '__main__':
    unittest.main()
