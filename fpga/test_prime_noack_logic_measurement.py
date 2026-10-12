"""Host contracts for the explicit mapper diagnostic; not RTL/timing passes."""
import copy
import json
import os
from pathlib import Path
import subprocess
import unittest

import prepare_prime_noack_logic_measurement as prepare


class LogicMeasurement(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PRIME_TIMING_ROOT']).resolve(strict=True)
        cls.original = {name: (cls.root/name).read_text() for name in (
            'synthesis/run.py', 'synthesis/audit_closed.py', 'clock-r2/run.py',
            'clock-r2/audit_closed.py', 'clock-r2/audit.tcl', 'after_prepare_synth.py')}
        cls.outputs = prepare.derive(cls.original)

    def test_monitors_and_limits_unchanged(self):
        for old, new in (('synthesis/run.py', 'synthesis-logic-r1/run.py'),
                         ('clock-r2/run.py', 'clock-logic-r1/run.py')):
            before, after = self.original[old], self.outputs[new]
            marker = 'owner = None\n'
            self.assertEqual(before[before.index(marker):], after[after.index(marker):])
            for guard in ('memory+swap > 13*gib', 'if free < 4*gib:',
                          'min(host.values()) < 2*gib', "VEN_FPGA_CORE_MHZ='40'",
                          "VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'"):
                self.assertIn(guard, after)
        synth = self.outputs['synthesis-logic-r1/run.py']
        self.assertIn('free-4*gib > 2*measured_disk_growth', synth)
        self.assertIn("'45m'", synth)

    def test_override_is_explicit_and_source_contract_preserved(self):
        for name in ('synthesis-logic-r1/run.py', 'clock-logic-r1/run.py'):
            text = self.outputs[name]
            self.assertIn("manifest['source_contract_synthesis_profile'] == 'balanced'", text)
            self.assertIn("VEN_FPGA_BUILD_PROFILE='logic_only'", text)
            self.assertIn("source = root.parent/'fpga-r1'", text)
        text = self.outputs['synthesis-logic-r1/audit_closed.py']
        self.assertIn('((synth,mapper),(old_synth,mapper))', text)
        self.assertIn('matched_mapper=True', text)
        self.assertNotIn("mapper.replace(' -no_timing_driven','')", text)

    def test_report_guard_executes_in_tcl(self):
        for options, directive, expected in (('-no_timing_driven', 'Default', 0),
                ('', 'Default', 1), ('-no_timing_driven', 'AreaOptimized_high', 1),
                ('-no_timing_driven -retiming', 'Default', 1)):
            stub = '''proc get_property {name obj} {
    if {$name eq "STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS"} {return $::env(TEST_OPTIONS)}
    if {$name eq "STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE"} {return $::env(TEST_DIRECTIVE)}
    error "unexpected property $name"
}
set synth synth_1
'''
            command = stub+'if {[catch {\n'+prepare.LOGIC_GUARD+'\n} why]} {puts stderr $why; exit 1}\n'
            result = subprocess.run(['tclsh'], input=command, text=True, capture_output=True,
                env=dict(os.environ, TEST_OPTIONS=options, TEST_DIRECTIVE=directive), timeout=10)
            self.assertEqual(result.returncode, expected, result.stderr)
        before = self.original['clock-r2/audit.tcl']
        after = self.outputs['clock-logic-r1/audit.tcl']
        self.assertEqual(after.replace(prepare.LOGIC_GUARD, prepare.NEW_GUARD), before)

    def test_queue_has_fresh_owners_and_correct_dependencies(self):
        text = self.outputs['after_prime_logic.py']
        self.assertIn("assert not state(unit)['InvocationID']", text)
        self.assertIn("unit='ventium-prime-noack-logic-'+label+'-oct12.service'", text)
        self.assertIn("root/'synthesis-logic-r1/audit_closed.py'", text)
        self.assertIn("root/'clock-logic-r1/audit_closed.py'", text)
        self.assertNotIn("root/'clock/", text)
        self.assertNotIn("root/'synthesis/", text)
        clock = self.outputs['clock-logic-r1/run.py']
        self.assertIn(prepare.SYNTH, clock)
        self.assertIn("synthesis = root.parent/'synthesis-logic-r1'", clock)
        self.assertIn("synthesized_40mhz_requirement_met=timing['unplaced_core_estimate_mhz']>=40", text)

    def test_actual_resource_stop_and_negative_evidence(self):
        root = self.root/'synthesis'
        self.assertEqual(prepare.sha(root/'closed.json'), prepare.STOP_SHA)
        self.assertEqual(prepare.sha(str(root/'closed.json')), prepare.STOP_SHA)
        start = json.loads((root/'started.json').read_text())
        closed = json.loads((root/'closed.json').read_text())
        samples = [json.loads(x) for x in (root/'watch.jsonl').read_text().splitlines()]
        owner = dict(InvocationID=prepare.SYNTH_INV, MainPID='0', SubState='failed',
                     ExecMainStatus='1', Result='exit-code')
        queue = dict(owner, InvocationID=prepare.QUEUE_INV)
        prepare.validate_stop(start, closed, samples, owner, queue)
        for field, value in (('native_exit', 0), ('inputs_unchanged', False),
                              ('resource_stop', 'disk reserve'), ('controller_failure', 'oops')):
            with self.assertRaises(AssertionError):
                prepare.validate_stop(start, dict(closed, **{field:value}), samples, owner, queue)
        altered = copy.deepcopy(samples)
        altered[-1]['events']['oom_kill'] = 1
        with self.assertRaises(AssertionError):
            prepare.validate_stop(start, closed, altered, owner, queue)
        with self.assertRaises(AssertionError):
            prepare.validate_stop(start, closed, samples, dict(owner, MainPID='123'), queue)

    def test_guard_drift_and_reapplication_rejected(self):
        altered = dict(self.original)
        altered['synthesis/run.py'] = altered['synthesis/run.py'].replace('if free < 4*gib:', 'if free < 1*gib:')
        with self.assertRaises(AssertionError):
            prepare.derive(altered)
        altered = dict(self.original)
        altered['clock-r2/audit.tcl'] = self.outputs['clock-logic-r1/audit.tcl']
        with self.assertRaises(AssertionError):
            prepare.derive(altered)


if __name__ == '__main__':
    unittest.main()
