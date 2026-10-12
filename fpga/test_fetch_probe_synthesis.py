"""Exact-source admission and unchanged lifecycle for the fetch-probe experiment."""
import unittest
import prepare_fetch_probe_synthesis as recipe


class PreparationTests(unittest.TestCase):
    def originals(self):
        result = {}
        for name, digest in recipe.TEMPLATES.items():
            p = recipe.PARENT/name
            self.assertEqual(recipe.sha(p), digest)
            result[name] = p.read_text()
        return result

    def test_lifecycle_and_modes_unchanged(self):
        original = self.originals(); output = recipe.derive(original)
        for phase in ('synthesis', 'clock'):
            key = phase+'-r1/run.py'
            recipe.guarded(output['probe-'+key], original[key])
            self.assertIn("len(manifest['hardware_defines']) == 158", output['probe-'+key])
        synth = output['probe-synthesis-r1/run.py']
        for expression in ('shutil.disk_usage(root).free > 6*gib',
                           'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                           "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']",
                           "changes=['rtl/core/core.sv']", "prepared['added_defines']==[]",
                           "'probe-payload-core-r1/verify-closed.json'", "'probe-soc-r1/coremark'"):
            self.assertIn(expression, synth)
        self.assertIn("manifest['hardware_defines'] == old_manifest['hardware_defines']",
                      output['probe-synthesis-r1/audit_closed.py'])
        self.assertEqual(output['probe-clock-r1/audit.tcl'], original['clock-r1/audit.tcl'])

    def test_drift_rejected(self):
        original = self.originals()
        original['synthesis-r1/run.py'] = original['synthesis-r1/run.py'].replace(
            "changes=['rtl/core/core_load.svh']", "changes=['rtl/core/core.sv']")
        with self.assertRaises(AssertionError): recipe.derive(original)


if __name__ == '__main__': unittest.main()
