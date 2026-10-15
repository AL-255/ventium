"""Protect timing audit scope, source identity and native completion guards."""
import unittest

import prepare_v_result_carry_clock as p


class ClockAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n: (p.ROOT/'pipe-wait-clock-r1'/n).read_text() for n in p.TEMPLATES}
        cls.output = p.derive(cls.original)

    def test_resource_and_native_lifetime_unchanged(self):
        new, old = self.output['run.py'], self.original['run.py']
        p.guarded(new, old)
        for before, after in (("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                              ('memory+swap > 11*gib', 'memory+swap > 30*gib'),
                              ('if free < 4*gib:', 'if free < 1*gib:'),
                              ("assert json.loads((synthesis/'audit.json').read_text())['passed']", 'pass')):
            with self.assertRaises(AssertionError):
                p.guarded(new.replace(before, after), old)

    def test_current_synthesis_and_parent_are_distinct(self):
        new = self.output['run.py']
        self.assertIn("synthesis = root.parent/'v-result-carry-synthesis-r3'", new)
        self.assertIn(str(p.ROOT/'pipe-wait-synthesis-r1'), new)
        self.assertIn("SubState='exited',MainPID='0',ExecMainStatus='0'", new)
        self.assertIn('processor_platform_simulator_sha256', new)
        self.assertIn('simulator_sha256\'] is None', new)
        self.assertIn(p.MANIFEST, new)
        self.assertIn(p.MODEL, new)
        self.assertIn('Canonical native exit 2 retained', new)
        self.assertNotIn('FUNC 108/108 with existing masks', new)

    def test_same_tcl_no_inherited_frequency_or_acceptance(self):
        self.assertEqual(self.output['audit.tcl'], self.original['audit.tcl'])
        audit = self.output['audit_closed.py']
        self.assertIn('parent_worst - (-1.350)', audit)
        self.assertIn('isolated_v_result_gain=False', audit)
        self.assertIn('physical_frequency_mhz=None, routed=False', audit)
        self.assertIn('1000/(25-worst)', audit)
        self.assertIn('hardware_acceptance=False, standard_suite=False', audit)
        for n, content in self.output.items():
            self.assertEqual((p.ROOT/'v-result-carry-clock-r1'/n).read_text(), content)

    def test_modified_template_rejected(self):
        changed = dict(self.original)
        changed['audit.tcl'] += '\nlaunch_runs impl_1\n'
        with self.assertRaises(AssertionError):
            p.derive(changed)


if __name__ == '__main__':
    unittest.main()
