"""Offline APR measurement guards; not processor/hardware acceptance."""
from pathlib import Path
import tempfile
import unittest
from run_apr_trial import validate_timing, validate_reports


TIMING = ('from_clock\tto_clock\tsetup_ns\thold_ns\tperiod_ns\trequirement_ns\texception\tconditional_mhz\n'
          'mmcm_clk\tmmcm_clk\t-9.841\t0.004\t25\t25\t\t28.701816825\n'
          'clk_pl_0\tclk_pl_0\t5.935\t0.012\t10\t10\t\t246.002460025\n'
          'mmcm_clk\tclk_pl_0\t0.113\t0.02\t10\t5\t\tNA\n'
          'clk_pl_0\tmmcm_clk\t1.187\t0.03\t25\t5\t\tNA\n')


class AprTests(unittest.TestCase):
    def test_frequency_derived_from_period_not_reciprocal_slack(self):
        result = validate_timing(TIMING)
        self.assertAlmostEqual(result[0]['conditional_mhz'], 1000/34.841)

    def test_missing_domain(self):
        with self.assertRaises(ValueError): validate_timing('\n'.join(TIMING.splitlines()[:-1]))

    def test_duplicate_domain(self):
        with self.assertRaises(ValueError): validate_timing(TIMING+TIMING.splitlines()[1]+'\n')

    def test_no_clock_relaxation(self):
        with self.assertRaises(ValueError): validate_timing(TIMING.replace('\t25\t25\t', '\t30\t30\t'))

    def test_no_multicycle_frequency_claim(self):
        with self.assertRaises(ValueError): validate_timing(TIMING.replace('\t25\t25\t', '\t25\t50\t'))
        with self.assertRaises(ValueError): validate_timing(TIMING.replace('\t25\t25\t\t', '\t25\t25\tMulticycle\t'))

    def test_no_cross_domain_frequency_claim(self):
        with self.assertRaises(ValueError): validate_timing(TIMING.replace('\tNA\n', '\t200\n'))

    def test_nonfinite_timing_rejected(self):
        for value in ('nan', 'inf', '-inf'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_timing(TIMING.replace('-9.841', value))

    def test_inconsistent_frequency_rejected(self):
        with self.assertRaises(ValueError): validate_timing(TIMING.replace('28.701816825', '40'))

    def test_native_route_and_hold_guard(self):
        with tempfile.TemporaryDirectory(prefix='apr-test-') as name:
            build = Path(name)
            route = '# of routable nets.... : 224107 :\n# of fully routed nets.... : 224107 :\n# of nets with routing errors.... : 0 :\n'
            (build/'after-route-status.rpt').write_text(route)
            (build/'drc.rpt').write_text('Design State : Fully Routed\n| Warning |\n')
            (build/'before-timing.tsv').write_text(TIMING)
            (build/'after-timing.tsv').write_text(TIMING)
            self.assertTrue(validate_reports(build)['hold_nonnegative'])
            (build/'after-timing.tsv').write_text(TIMING.replace('\t0.004\t', '\t-0.004\t'))
            self.assertFalse(validate_reports(build)['hold_nonnegative'])
            (build/'after-route-status.rpt').write_text(route.replace('errors.... : 0', 'errors.... : 1'))
            with self.assertRaises(ValueError): validate_reports(build)
            (build/'after-route-status.rpt').write_text(route)
            (build/'drc.rpt').write_text('Design State : Fully Routed\n| Critical Warning |\n')
            with self.assertRaises(ValueError): validate_reports(build)


if __name__ == '__main__': unittest.main()
