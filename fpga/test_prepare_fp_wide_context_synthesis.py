"""Preserve native safeguards and the actual 34.113 MHz control checkpoint."""
import unittest

import prepare_fp_wide_context_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in prepare.TEMPLATES.items():
            path = prepare.ROOT/name
            assert prepare.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.changes = {'ventium/'+n: prepare.sha(prepare.ROOT/'fp-wide-context-core-r1/candidate'/n)
                       for n in prepare.native.CHANGES}
        cls.output = prepare.derive(cls.original, cls.changes)

    def test_resource_lifecycle(self):
        for phase in ('synthesis', 'clock'):
            text = self.output['fp-wide-context-'+phase+'-r1/run.py']
            prepare.guarded(text, self.original['payload-region-'+phase+'-r1/run.py'])
            for marker in ("VEN_FPGA_JOBS='1'", "VEN_FPGA_CORE_MHZ='40'",
                           "VEN_FPGA_BUILD_PROFILE='logic_only'", 'disk_stop_floor=4*gib'):
                self.assertIn(marker, text)
        text = self.output['fp-wide-context-synthesis-r1/run.py']
        for marker in ('free > 6*gib', '> 2*measured_disk_growth',
                       "len(reg['rows'])==12", "len(fp['measurements'])==1536",
                       "len(replay['rows'])==108 and replay['records']==80800",
                       "not verify['canonical_gate_passed']", '[4767218,4753406]',
                       prepare.native.CORE_MODEL, 'changes='+repr(prepare.native.CHANGES)):
            self.assertIn(marker, text)

    def test_matched_control_and_original_clocks(self):
        text = self.output['fp-wide-context-synthesis-r1/audit_closed.py']
        self.assertIn(str(prepare.ROOT/'payload-region-synthesis-r1'), text)
        self.assertIn(str(prepare.ROOT/'payload-region-fpga-r1'), text)
        self.assertIn('expected_changes='+repr(self.changes), text)
        self.assertIn(prepare.PARENT_MANIFEST, text)
        text = self.output['fp-wide-context-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'payload-region-synthesis-r1'), text)
        self.assertIn(prepare.PARENT_DCP, text)
        self.assertIn('(-4.314)', self.output['fp-wide-context-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['fp-wide-context-clock-r1/audit.tcl'],
                         self.original['payload-region-clock-r1/audit.tcl'])

    def test_reject_extra_or_missing_delta(self):
        for bad in ({}, dict(self.changes, other='0'*64)):
            with self.assertRaises(AssertionError):
                prepare.derive(self.original, bad)


if __name__ == '__main__':
    unittest.main()
