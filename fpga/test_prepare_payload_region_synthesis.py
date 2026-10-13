"""Preserve guards, proof admission and the actual 33.15 MHz parent checkpoint."""
import unittest
import prepare_payload_region_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name,digest in prepare.TEMPLATES.items():
            path = prepare.ROOT/name
            assert prepare.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.changes = {'ventium/'+n:prepare.sha(prepare.ROOT/'payload-region-core-r1/candidate'/n)
                       for n in prepare.native.CHANGES}
        cls.output = prepare.derive(cls.original, cls.changes)

    def test_resource_lifecycle(self):
        for phase in ('synthesis','clock'):
            text = self.output['payload-region-'+phase+'-r1/run.py']
            prepare.guarded(text, self.original['intent-ready-'+phase+'-r1/run.py'])
            for marker in ("VEN_FPGA_JOBS='1'", "VEN_FPGA_CORE_MHZ='40'",
                           "VEN_FPGA_BUILD_PROFILE='logic_only'", 'disk_stop_floor=4*gib'):
                self.assertIn(marker, text)
        text = self.output['payload-region-synthesis-r1/run.py']
        for marker in ('free > 6*gib', '> 2*measured_disk_growth',
                       "len(reg['rows'])==12", "len(fp['measurements'])==1536",
                       "len(replay['rows'])==108 and replay['records']==80800",
                       "not verify['canonical_gate_passed']", '[4767218,4753406]',
                       prepare.native.CORE_MODEL, 'changes='+repr(prepare.native.CHANGES)):
            self.assertIn(marker, text)

    def test_matching_source_and_timing_controls(self):
        text = self.output['payload-region-synthesis-r1/audit_closed.py']
        self.assertIn(str(prepare.ROOT/'intent-ready-synthesis-r1'), text)
        self.assertIn(str(prepare.ROOT/'intent-ready-fpga-r1'), text)
        self.assertIn('expected_changes='+repr(self.changes), text)
        self.assertIn(prepare.PARENT_MANIFEST, text)
        text = self.output['payload-region-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'intent-ready-synthesis-r1'), text)
        self.assertIn(prepare.PARENT_DCP, text)
        self.assertIn('(-5.162)', self.output['payload-region-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['payload-region-clock-r1/audit.tcl'],
                         self.original['intent-ready-clock-r1/audit.tcl'])

    def test_reject_extra_or_missing_delta(self):
        for bad in ({}, dict(self.changes, other='0'*64)):
            with self.assertRaises(AssertionError): prepare.derive(self.original,bad)


if __name__ == '__main__': unittest.main()
