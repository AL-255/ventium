import unittest
import prepare_rem_split_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.templates = {}
        for name,digest in prepare.TEMPLATES.items():
            path = prepare.PARENT/name
            assert prepare.sha(path) == digest
            cls.templates[name] = path.read_text()

    def test_native_lifecycle_and_admission_are_preserved(self):
        result = prepare.derive(self.templates)
        self.assertEqual(len(result),5)
        for phase in ('synthesis','clock'):
            source = result[phase+'-r1/run.py']
            prepare.guarded(source,self.templates['payload-current-'+phase+'-r1/run.py'])
            self.assertIn("len(manifest['hardware_defines']) == 158",source)
            self.assertIn("manifest['core_mhz'] == 40",source)
        self.assertIn('shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',result['synthesis-r1/run.py'])
        self.assertIn("not verify['canonical_gate_passed']",result['synthesis-r1/run.py'])
        self.assertIn(prepare.PARENT_DCP,result['clock-r1/run.py'])
        self.assertIn('(-7.998)',result['clock-r1/audit_closed.py'])
        self.assertEqual(result['clock-r1/audit.tcl'],self.templates['payload-current-clock-r1/audit.tcl'])

    def test_drift_and_resource_weakening_rejected(self):
        wrong = dict(self.templates)
        key = 'payload-current-synthesis-r1/run.py'
        wrong[key] = wrong[key].replace("manifest['variant'] == 'payload_current_timing'",'True')
        with self.assertRaises(AssertionError): prepare.derive(wrong)
        result = prepare.derive(self.templates)
        with self.assertRaises(AssertionError):
            prepare.guarded(result['synthesis-r1/run.py'].replace('memory+swap > 13*gib','memory+swap > 20*gib'),self.templates[key])


if __name__ == '__main__': unittest.main()
