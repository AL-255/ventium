"""Check source identities and unchanged synthesis/stop/reap safeguards."""
import unittest
import prepare_load_read_ack_synthesis as recipe


class PreparationTests(unittest.TestCase):
    def originals(self):
        result={}
        for name,digest in recipe.TEMPLATES.items():
            p=recipe.PARENT/name
            self.assertEqual(recipe.sha(p),digest)
            result[name]=p.read_text()
        return result

    def test_only_source_identity_changes_not_controller_lifecycle(self):
        original=self.originals()
        output=recipe.derive(original)
        for phase in ('synthesis','clock'):
            key=phase+'-r1/run.py'
            recipe.guarded(output[key],original[key])
            self.assertIn("len(manifest['hardware_defines']) == 158",output[key])
        synth=output['synthesis-r1/run.py']
        for expression in ('shutil.disk_usage(root).free > 6*gib',
                           'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                           "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']"):
            self.assertIn(expression,synth)
        self.assertIn("changes=['rtl/core/core_load.svh']",synth)
        self.assertIn("prepared['added_defines']==[]",synth)
        self.assertIn("manifest['hardware_defines'] == old_manifest['hardware_defines']",
                      output['synthesis-r1/audit_closed.py'])
        self.assertEqual(output['clock-r1/audit.tcl'],original['clock-r1/audit.tcl'])

    def test_drift_rejected(self):
        original=self.originals()
        original['synthesis-r1/run.py']=original['synthesis-r1/run.py'].replace(
            "prepared['added_defines']==['VEN_SRT_REM_OPERAND_SPLIT']",'prepared["added_defines"]==[]')
        with self.assertRaises(AssertionError): recipe.derive(original)


if __name__=='__main__': unittest.main()
