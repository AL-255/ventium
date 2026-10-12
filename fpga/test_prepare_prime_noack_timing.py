"""Host checks of timing-controller derivation; not hardware verification."""
import os
from pathlib import Path
import unittest

import prepare_prime_noack_timing as prepare


class ControllerContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['PRIME_TIMING_PARENT']).resolve(strict=True)
        cls.original = {}
        for name, digest in prepare.TEMPLATES.items():
            assert prepare.sha(parent/name) == digest
            cls.original[name] = (parent/name).read_text()
        cls.outputs = prepare.derive(cls.original)

    def test_native_monitor_and_resource_guards_unchanged(self):
        for name in ('synthesis/run.py', 'clock/run.py'):
            before, after = self.original[name], self.outputs[name]
            marker = 'owner = None\n'
            self.assertEqual(before[before.index(marker):], after[after.index(marker):])
            for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                          'if free < 4*gib:', 'memory+swap > 13*gib', 'min(host.values()) < 2*gib'):
                self.assertIn(guard, after)

    def test_mapper_change_explicit_not_a_clock_waiver(self):
        synth = self.outputs['synthesis/run.py']
        self.assertIn("VEN_FPGA_BUILD_PROFILE='balanced'", synth)
        self.assertIn("VEN_FPGA_CORE_MHZ='40'", synth)
        self.assertIn('canonical_gate_native_exit', synth)
        audit = self.outputs['synthesis/audit_closed.py']
        self.assertIn('synthesis_profile_changed=True', audit)
        self.assertIn('isolated_rtl_gain_claimed=False', audit)
        self.assertIn("mapper.replace(' -no_timing_driven','')", audit)

    def test_native_prerequisites_and_duplicate_prevention(self):
        self.assertIn('6103040', self.outputs['synthesis/run.py'])
        self.assertIn('80800', self.outputs['synthesis/run.py'])
        self.assertIn('12096', self.outputs['synthesis/run.py'])
        self.assertIn('13888', self.outputs['synthesis/run.py'])
        self.assertIn("assert not state(unit)['InvocationID']", self.outputs['after_prepare_synth.py'])
        owner = dict(InvocationID='expected', MainPID='0', SubState='exited',
                     ExecMainStatus='0', Result='success')
        prepare.require_closed_owner(owner, 'expected')
        for field, value in (('InvocationID', 'stale'), ('MainPID', '123'),
                             ('SubState', 'running'), ('ExecMainStatus', '1'), ('Result', 'oom-kill')):
            with self.assertRaises(AssertionError):
                prepare.require_closed_owner(dict(owner, **{field: value}), 'expected')

    def test_guard_drift_rejected(self):
        altered = dict(self.original)
        altered['synthesis/run.py'] = altered['synthesis/run.py'].replace('if free < 4*gib:', 'if free < 1*gib:')
        with self.assertRaises(AssertionError):
            prepare.derive(altered)


if __name__ == '__main__':
    unittest.main()
