"""Verify unchanged safety limits, modes and measured-parent timing comparison."""
import unittest
import prepare_memdiv_capture_synthesis as recipe


class PreparationTests(unittest.TestCase):
    def originals(self):
        result = {}
        for name, digest in recipe.TEMPLATES.items():
            p = recipe.ROOT/name
            self.assertEqual(recipe.sha(p), digest)
            result[name] = p.read_text()
        return result

    def test_guard_profile_and_evidence_preserved(self):
        before = self.originals(); after = recipe.derive(before)
        for phase in ('synthesis', 'clock'):
            text = after['memdiv-'+phase+'-r1/run.py']
            recipe.guarded(text,before['probe-'+phase+'-r1/run.py'])
            self.assertIn("len(manifest['hardware_defines']) == 158",text)
        synth = after['memdiv-synthesis-r1/run.py']
        for text in ('shutil.disk_usage(root).free > 6*gib',
                     'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                     "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']",
                     "core['changes']==changes[:1]", "prepared['changes']==changes",
                     "prepared['added_defines']==[]", "'memdiv-soc-r1/coremark'",
                     "[4767218,4753406]", "'memdiv-core-r1/verify-closed.json'"):
            self.assertIn(text,synth)
        self.assertIn("manifest['hardware_defines'] == old_manifest['hardware_defines']",
                      after['memdiv-synthesis-r1/audit_closed.py'])
        self.assertIn('(-7.800)',after['memdiv-clock-r1/audit_closed.py'])
        self.assertEqual(after['memdiv-clock-r1/audit.tcl'],before['probe-clock-r1/audit.tcl'])

    def test_source_admission_drift_rejected(self):
        before = self.originals()
        before['probe-synthesis-r1/run.py'] = before['probe-synthesis-r1/run.py'].replace(
            "changes=['rtl/core/core.sv']", "changes=['rtl/core/core_load.svh']")
        with self.assertRaises(AssertionError): recipe.derive(before)


if __name__ == '__main__': unittest.main()
