#!/usr/bin/env python3
"""Parser safety checks; no Vivado, RTL build, or generated run directory."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from analyze_setup_paths import analyze


HEADER = """| Command           : report_timing -delay_type max -path_type full_clock_expanded
| Design State      : Synthesized
"""
PATH = """Slack (VIOLATED) : -1.250ns (required time - arrival time)
  Source: cpu/pc_reg[0]/C
    (rising edge-triggered cell FDRE clocked by mmcm_clk {rise@0.000ns fall@12.500ns period=25.000ns})
  Destination: cpu/result_reg[3]/CE
    (rising edge-triggered cell FDRE clocked by mmcm_clk {rise@0.000ns fall@12.500ns period=25.000ns})
  Path Group: mmcm_clk
  Path Type: Setup (Max at Slow Process Corner)
  Requirement: 25.000ns (mmcm_clk rise@25.000ns - mmcm_clk rise@0.000ns)
  Data Path Delay: 26.000ns (logic 6.000ns (23.077%) route 20.000ns (76.923%))
  Logic Levels: 2 (LUT6=1 CARRY8=1)
    Source Clock Delay (SCD): 2.000ns
    Location Delay type Incr(ns) Path(ns) Netlist Resource(s)
          net (fo=10, unplaced) 2.000 2.000 cpu/clk
          FDRE r cpu/pc_reg[0]/C
  -------------------------------------------------------------------
          FDRE (Prop_FDRE_C_Q) 1.000 3.000 r cpu/pc_reg[0]/Q
          net (fo=1, unplaced) 10.000 13.000 cpu/pc
          LUT6 (Prop_LUT6_I0_O) 2.000 15.000 r cpu/lookup/O
          net (fo=2, unplaced) 10.000 25.000 cpu/lookup
          CARRY8 (Prop_CARRY8_CI_O[0])
                               3.000 28.000 r cpu/result/O[0]
          FDRE r cpu/result_reg[3]/CE
  -------------------------------------------------------------------
          (clock mmcm_clk rise edge)
                              25.000 25.000 r
          net (fo=10, unplaced) 2.000 27.000 cpu/clk
          required time 26.750
          arrival time -28.000
          slack -1.250
"""


class ReportTests(unittest.TestCase):
    def test_data_only_and_wrapped_primitive(self):
        result = analyze(HEADER + PATH, [('lookup', r'/lookup$')])
        path = result['paths'][0]
        self.assertEqual(len(path['rows']), 5)
        self.assertEqual(path['segments'][0]['delay_ns'], 23)
        self.assertEqual(path['segments'][1]['delay_ns'], 3)
        self.assertEqual(sum(s['delay_ns'] for s in path['segments']), 26)
        self.assertAlmostEqual(result['estimated_fmax_mhz'], 1000 / 26.25)
        self.assertFalse(result['routed'])
        self.assertIsNone(result['physical_frequency_mhz'])

    def test_groups_bit_endpoints_not_independent_bottlenecks(self):
        result = analyze(HEADER + PATH + PATH.replace('result_reg[3]', 'result_reg[4]'))
        self.assertEqual(result['endpoint_families'], {'cpu/result_reg[*]/CE': 2})

    def test_optimized_default_max_report_requires_explicit_state(self):
        report = HEADER.replace('Synthesized', 'Optimized').replace(' -delay_type max', '') + PATH
        with self.assertRaisesRegex(ValueError, 'expected synthesized'):
            analyze(report)
        result = analyze(report, expected_state='Optimized')
        self.assertEqual(result['design_state'], 'Optimized')
        self.assertEqual(result['paths'][0]['logic_levels'], 2)
        self.assertFalse(result['routed'])
        self.assertFalse(result['timing_signoff'])

    def test_routed_locations_wrapped_and_unwrapped(self):
        report = HEADER.replace('Synthesized', 'Routed') + PATH.replace(
            '          CARRY8 (Prop_', '    SLICE_X72Y304 CARRY8 (Prop_').replace(
            '          FDRE (Prop_', '    SLICE_X72Y304 FDRE (Prop_')
        result = analyze(report, expected_state='Routed')
        self.assertTrue(result['routed'])
        self.assertFalse(result['timing_signoff'])
        self.assertIsNone(result['physical_frequency_mhz'])
        self.assertEqual(result['paths'][0]['data_delay_ns'], 26)
        self.assertAlmostEqual(result['estimated_fmax_mhz'], 1000 / 26.25)

    def test_explicit_state_must_match_and_be_supported(self):
        for state in ('Optimized', 'Routed', 'Placed', ''):
            with self.subTest(state=state), self.assertRaises(ValueError):
                analyze(HEADER + PATH, expected_state=state)

    def test_default_max_does_not_admit_hold_or_mixed_paths(self):
        header = HEADER.replace(' -delay_type max', '')
        with self.assertRaisesRegex(ValueError, 'Path Type'):
            analyze(header + PATH + PATH.replace('Setup (Max', 'Hold (Min'))
        for option in (' -hold', ' -delay_type min', ' -delay_type min_max'):
            with self.subTest(option=option), self.assertRaisesRegex(ValueError, 'setup report'):
                analyze(header.replace('report_timing', 'report_timing' + option) + PATH)

    def test_verdict_must_agree_with_slack(self):
        with self.assertRaisesRegex(ValueError, 'slack sign'):
            analyze(HEADER + PATH.replace('Slack (VIOLATED)', 'Slack (MET)'))

    def test_cli_requires_state_and_keeps_report_unchanged(self):
        with tempfile.TemporaryDirectory() as root:
            report = Path(root) / 'optimized paths.rpt'
            raw = (HEADER.replace('Synthesized', 'Optimized') + PATH).encode()
            report.write_bytes(raw)
            command = [sys.executable, '-B', str(Path(__file__).with_name('analyze_setup_paths.py')),
                       str(report)]
            rejected = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            accepted = subprocess.run(command + ['--state', 'Optimized'], text=True,
                                      capture_output=True, check=True)
            result = json.loads(accepted.stdout)
            self.assertEqual(result['design_state'], 'Optimized')
            self.assertEqual(result['paths_reported'], 1)
            self.assertNotIn('rows', result['paths'][0])
            self.assertEqual(report.read_bytes(), raw)

    def test_missing_marker_keeps_remainder(self):
        result = analyze(HEADER + PATH, [('absent', r'/absent$')])
        self.assertEqual(result['paths'][0]['segments'][0]['delay_ns'], 26)
        self.assertEqual(len(result['paths'][0]['segments']), 1)

    def test_marker_ambiguity_is_not_silently_resolved(self):
        with self.assertRaisesRegex(ValueError, 'ambiguous marker'):
            analyze(HEADER + PATH, [('too_broad', r'lookup')])

    def test_bad_or_unsupported_inputs(self):
        cases = [
            (HEADER.replace('Synthesized', 'Routed') + PATH, 'synthesized'),
            (HEADER.replace('full_clock_expanded', 'short') + PATH, 'full_clock'),
            (HEADER + PATH.replace('Setup (Max', 'Hold (Min'), 'Path Type'),
            (HEADER + PATH.replace('Requirement: 25.000', 'Requirement: 50.000'), 'single-period'),
            (HEADER + PATH.replace('25.000ns})', '10.000ns})', 1), 'identical endpoint'),
            (HEADER + PATH.replace('route 20.000ns', 'route 19.000ns'), 'does not add up'),
            (HEADER + PATH.replace('10.000 25.000', '10.000 24.000'), 'discontinuous'),
            (HEADER + PATH.replace('CARRY8 (Prop_CARRY8_CI_O[0])', 'unknown-format'), 'unparsed'),
            (HEADER + PATH.replace('FDRE r cpu/result_reg[3]/CE', ''), 'unparsed'),
            (HEADER + PATH.split('\n          required time')[0], 'required time'),
            (HEADER + PATH.replace('arrival time -28.000', 'arrival time -27.000'), 'footer disagrees'),
            (HEADER, 'no setup paths'),
        ]
        for report, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    analyze(report)


if __name__ == '__main__':
    unittest.main()
