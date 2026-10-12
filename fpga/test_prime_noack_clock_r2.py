"""Execute reporter profile guards under Tcl without running Vivado."""
import os
from pathlib import Path
import subprocess
import unittest

import prepare_prime_noack_clock_r2 as repair


class ClockRepair(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PRIME_TIMING_ROOT']).resolve(strict=True)
        cls.original = {n: (cls.root/n).read_text() for n in (
            'clock/run.py', 'clock/audit_closed.py', 'clock/audit.tcl', 'after_prepare_synth.py')}
        cls.outputs = repair.derive(cls.original)

    def guard(self, options, directive, original=False):
        source = self.original['clock/audit.tcl'] if original else self.outputs['clock-r2/audit.tcl']
        prefix = source.split('\nopen_run synth_1\n')[0]
        stub = '''set argc 5
set argv {project.xpr output parent.dcp hash parent.xpr}
proc set_param {args} {}
proc open_project {args} {}
proc get_runs {name} {return $name}
proc get_property {name obj} {
    switch -- $name {
        PROGRESS {return 100%}
        STATUS {if {$obj eq "synth_1"} {return "synth_design Complete!"}; return "Not started"}
        NEEDS_REFRESH {return false}
        {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} {return $::env(TEST_OPTIONS)}
        STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE {return $::env(TEST_DIRECTIVE)}
        default {error "unexpected property $name"}
    }
}
'''
        # Tcl stdin otherwise reports an error but continues to the next command.
        script = stub+'if {[catch {\n'+prefix+'\n} why]} {puts stderr $why; exit 1}\nputs GUARD-PASSED\n'
        return subprocess.run(['tclsh'], input=script, text=True, capture_output=True,
            env=dict(os.environ, TEST_OPTIONS=options, TEST_DIRECTIVE=directive), timeout=10)

    def test_default_timing_driven_admitted(self):
        result = self.guard('', 'Default')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('GUARD-PASSED', result.stdout)

    def test_original_guard_rejects_actual_candidate_profile(self):
        result = self.guard('', 'Default', original=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not the requested logic-only synthesis', result.stderr)

    def test_other_mappers_rejected(self):
        for opts, directive in (('-no_timing_driven', 'Default'), ('', 'AreaOptimized_high'),
                                ('-retiming', 'Default')):
            result = self.guard(opts, directive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not the requested Default timing-driven synthesis', result.stderr)

    def test_reports_and_native_monitor_unchanged(self):
        before = self.original['clock/audit.tcl']
        after = self.outputs['clock-r2/audit.tcl']
        self.assertEqual(after.replace(repair.NEW_GUARD, repair.OLD_GUARD), before)
        marker = 'owner = None\n'
        before = self.original['clock/run.py']; after = self.outputs['clock-r2/run.py']
        self.assertEqual(before[before.index(marker):], after[after.index(marker):])
        queue = self.outputs['after_clock_repair.py']
        self.assertNotIn("launch('synth'", queue)
        self.assertIn(repair.SYNTH_INV, queue)
        self.assertIn("assert label=='clock'", queue)
        self.assertIn("assert not state(unit)['InvocationID']", queue)

    def test_reapplication_rejected(self):
        original = dict(self.original, **{'clock/audit.tcl': self.outputs['clock-r2/audit.tcl']})
        with self.assertRaises(AssertionError): repair.derive(original)


if __name__ == '__main__':
    unittest.main()
