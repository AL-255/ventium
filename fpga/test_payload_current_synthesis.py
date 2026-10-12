"""Exact-template preparation and fail-closed resource-lifecycle checks."""
from pathlib import Path
import unittest

import prepare_payload_current_synthesis as candidate


class Preparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = candidate.TEMPLATE_ROOT.resolve(strict=True)/'prime-noack'
        cls.original = {}
        for name, digest in candidate.TEMPLATES.items():
            path = cls.parent/name
            assert candidate.sha(path) == digest
            cls.original[name] = path.read_text()

    def test_exact_templates_keep_monitor_and_resources(self):
        outputs = candidate.derive(self.original, self.parent)
        self.assertEqual(len(outputs), 5)
        for phase in ('synthesis', 'clock'):
            text = outputs['payload-current-'+phase+'-r1/run.py']
            candidate.guarded(text, self.original[phase+'-logic-r1/run.py'])
            self.assertIn("manifest['source_contract_synthesis_profile'] == 'logic_only'", text)
            self.assertIn("len(manifest['hardware_defines']) == 157", text)
            self.assertIn("manifest['core_mhz'] == 40", text)
        synth = outputs['payload-current-synthesis-r1/run.py']
        self.assertIn('shutil.disk_usage(root).free > 6*gib', synth)
        self.assertIn('shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth', synth)
        self.assertIn("not verify['canonical_gate_passed']", synth)
        self.assertEqual(outputs['payload-current-clock-r1/audit.tcl'], self.original['clock-logic-r1/audit.tcl'])

    def test_ambiguous_or_missing_rebase_refused(self):
        broken = dict(self.original)
        key = 'synthesis-logic-r1/run.py'
        broken[key] = broken[key].replace("manifest['variant'] == 'prime_noack_timing'", 'True')
        with self.assertRaises(AssertionError):
            candidate.derive(broken, self.parent)

    def test_guard_and_native_audit_not_weakened(self):
        outputs = candidate.derive(self.original, self.parent)
        key = 'payload-current-synthesis-r1/run.py'
        with self.assertRaises(AssertionError):
            candidate.guarded(outputs[key].replace('memory+swap > 13*gib', 'memory+swap > 18*gib'),
                              self.original['synthesis-logic-r1/run.py'])
        audit = outputs['payload-current-synthesis-r1/audit_closed.py']
        self.assertIn("definition_groups[0].split() == manifest['hardware_defines']", audit)
        self.assertIn("manifest['hardware_defines'].index('VEN_L1D_PAYLOAD_CODE_HINT') == 153", audit)
        self.assertIn('parent_defines_retained=True', audit)
        self.assertIn('dcp.testzip() is None', audit)


if __name__ == '__main__':
    unittest.main()
