import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from audit_fresh_result import timing_summary, timing_coverage, route_and_drc, bus_skew, audit_closed, sha
from test_audit_fresh_strategy import SCRIPT, PROPS

PASS = '''| Design Timing Summary
0.150 0.000 0 200000 0.004 0.000 0 200000 2.000 0.000 0 60000
All user specified timing constraints are met.
| Clock Summary
'''
NAMES = ('no_clock', 'constant_clock', 'pulse_width_clock', 'unconstrained_internal_endpoints',
         'no_input_delay', 'no_output_delay', 'multiple_clock', 'generated_clocks', 'loops',
         'partial_input_delay', 'partial_output_delay', 'latch_loops')
COVERAGE = '\n'.join(f'{i}. checking {n} ({4 if n == "no_output_delay" else 0})' for i,n in enumerate(NAMES,1))+'\n'
COVERAGE = COVERAGE+COVERAGE+'\nled[0]\nled[1]\nled[2]\nled[3]\n'
ROUTE = '# of routable nets.... : 180000 :\n# of fully routed nets.... : 180000 :\n# of nets with routing errors.... : 0 :\n'
DRC = 'Design State : Fully Routed\n| Warning |\n'


class ResultTests(unittest.TestCase):
    def test_all_three_timing_checks_required(self):
        self.assertTrue(timing_summary(PASS)['all_numeric_timing_met'])
        for old, new in [('0.150', '-0.150'), ('0.004', '-0.004'), ('2.000', '-2.000')]:
            text = PASS.replace(old, new).replace('All user specified timing constraints are met.', 'Timing constraints are not met.')
            self.assertFalse(timing_summary(text)['all_numeric_timing_met'])
            with self.assertRaises(ValueError): timing_summary(PASS.replace(old, new))

    def test_nonfinite_truncated_and_empty_timing_rejected(self):
        for text in ('', PASS+PASS, PASS.replace('0.150', 'nan'), PASS.replace('200000', '0'),
                     PASS.replace('0 60000', '0')):
            with self.assertRaises(ValueError): timing_summary(text)

    def test_unconstrained_core_not_allowed(self):
        self.assertEqual(timing_coverage(COVERAGE)['no_output_delay'], 4)
        for text in (COVERAGE.replace('no_clock (0)', 'no_clock (1)'),
                     COVERAGE.replace('unconstrained_internal_endpoints (0)', 'unconstrained_internal_endpoints (1)'),
                     COVERAGE.replace('led[3]', 'cpu_data[0]'),
                     '\n'.join(COVERAGE.splitlines()[:12]),
                     COVERAGE.replace('latch_loops (0)', 'latch_loops (1)', 1)):
            with self.assertRaises(ValueError): timing_coverage(text)

    def test_routes_not_required_to_match_prior_net_count(self):
        # Different synthesis strategies may compact the netlist below 200k.
        self.assertEqual(route_and_drc(ROUTE, DRC)['fully routed nets'], 180000)
        for route, drc in ((ROUTE.replace('fully routed nets.... : 180000', 'fully routed nets.... : 179999'), DRC),
                           (ROUTE.replace('errors.... : 0', 'errors.... : 1'), DRC),
                           (ROUTE, DRC+'| Critical Warning |\n')):
            with self.assertRaises(ValueError): route_and_drc(route, drc)

    def test_bus_skew_constraints_must_all_remain(self):
        text = 'Slack (MET) : 9.000ns (requirement - actual skew)\n'*10
        self.assertTrue(bus_skew(text)['met'])
        negative = text.replace('Slack (MET) : 9.000ns', 'Slack (VIOLATED) : -0.001ns', 1)
        self.assertFalse(bus_skew(negative)['met'])
        for bad in (text.splitlines()[0], text.replace('9.000', 'nan'), text.replace('9.000', '-0.001')):
            with self.assertRaises(ValueError): bus_skew(bad)

    def test_known_parser_exception_does_not_hide_native_or_input_failures(self):
        with tempfile.TemporaryDirectory(prefix='fresh-result-test-') as td:
            run = Path(td); build = run/'build'; build.mkdir()
            source = run/'source.sv'; source.write_text('module a; endmodule\n')
            (run/'prepared.json').write_text('{}')
            started = dict(fresh_synthesis=True, prior_checkpoint_inputs=[], pins={str(source):sha(source)},
                           strategy='performance-netdelay', implementation_limit_seconds=13800)
            (run/'started.json').write_text(json.dumps(started))
            (run/'native.log').write_text('FRESH-STRATEGY-COMPLETE performance-netdelay\n')
            (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t400\n')
            script = build/'rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl'
            script.parent.mkdir(parents=True); script.write_text(SCRIPT)
            (build/'synth_1-properties.rpt').write_text(PROPS)
            (build/'impl_1-properties.rpt').write_text('AUTO_INCREMENTAL_CHECKPOINT bool false 0\nINCREMENTAL_CHECKPOINT file false\n')
            required = ('fresh-routed.dcp', 'rk_ao486_system.bit.bin', 'timing-summary.rpt',
                        'timing.tsv', 'check-timing.rpt', 'route-status.rpt', 'drc.rpt',
                        'bus-skew.rpt', 'cdc.rpt', 'exceptions.rpt')
            for name in required: (build/name).write_text('fixture only, never a native result\n')
            closed = dict(native_exit=0, reason=None, inputs_unchanged=True,
                          failure="audit: ValueError('flatten policy drift')", elapsed=350,
                          products={name:sha(build/name) for name in required})
            (run/'closed.json').write_text(json.dumps(closed))
            # Only parser/receipt control flow is under test. Numeric reports
            # are tested independently above; do not treat these as FPGA data.
            with patch('audit_fresh_result.final_reports', return_value={}):
                self.assertTrue(audit_closed(run)['native_completion_verified'])
                for key, value in (('native_exit', 1), ('reason', 'scope OOM'),
                                   ('inputs_unchanged', False), ('failure', 'audit: other failure')):
                    (run/'closed.json').write_text(json.dumps({**closed, key:value}))
                    with self.subTest(key=key), self.assertRaises(ValueError): audit_closed(run)
                (run/'closed.json').write_text(json.dumps(closed))
                (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t14000\n')
                with self.assertRaises(ValueError): audit_closed(run)
                (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t400\n')
                source.write_text('changed source\n')
                with self.assertRaises(ValueError): audit_closed(run)


if __name__ == '__main__': unittest.main()
