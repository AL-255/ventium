"""Check source/parent identities and unchanged native guards before export."""
import unittest

import prepare_read_owner_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in prepare.TEMPLATES.items():
            path = prepare.ROOT/name
            assert prepare.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.changes = {'ventium/'+p:prepare.sha(prepare.ROOT/'read-owner-core-r1/candidate'/p)
                       for p in prepare.native.CHANGES}
        cls.output = prepare.derive(cls.original, cls.changes)

    def test_unchanged_guard_lifecycle(self):
        for phase in ('synthesis', 'clock'):
            prepare.guarded(self.output['read-owner-'+phase+'-r1/run.py'],
                            self.original['pair-intent-'+phase+'-r1/run.py'])
        text = self.output['read-owner-synthesis-r1/run.py']
        for guard in ("VEN_FPGA_JOBS='1'", 'free > 6*gib', '> 2*measured_disk_growth',
                      "VEN_FPGA_CORE_MHZ='40'", "VEN_FPGA_BUILD_PROFILE='logic_only'"):
            self.assertIn(guard, text)

    def test_full_regressions_and_exact_replay_required(self):
        text = self.output['read-owner-synthesis-r1/run.py']
        self.assertIn('changes='+repr(prepare.native.CHANGES), text)
        self.assertIn(prepare.EXTRA_PROOF, text)
        self.assertIn("load_proof('read-owner-regressions-r1/replay/closed.json')", text)
        self.assertIn("len(replay['rows'])==108 and replay['records']==80800", text)
        self.assertIn("not verify['canonical_gate_passed']", text)
        self.assertIn(prepare.native.CORE_MODEL, text)

    def test_same_source_and_best_timing_parent(self):
        for phase in ('synthesis', 'clock'):
            name = 'read-owner-'+phase+'-r1/'+('audit_closed.py' if phase=='synthesis' else 'run.py')
            self.assertIn(str(prepare.ROOT/'pair-intent-synthesis-r1'), self.output[name])
        self.assertIn(prepare.PARENT_DCP, self.output['read-owner-clock-r1/run.py'])
        self.assertIn('(-6.594)', self.output['read-owner-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['read-owner-clock-r1/audit.tcl'],
                         self.original['pair-intent-clock-r1/audit.tcl'])

    def test_only_one_hardware_change(self):
        self.assertEqual(list(self.changes), ['ventium/rtl/mem/ven_l1d.sv'])
        text = self.output['read-owner-synthesis-r1/audit_closed.py']
        self.assertIn('expected_changes='+repr(self.changes), text)
        self.assertIn("assert manifest['hardware_defines'] == old_manifest['hardware_defines']", text)

    def test_reject_extra_or_missing_change(self):
        for bad in ({}, dict(self.changes, unreviewed='0'*64)):
            with self.assertRaises(AssertionError): prepare.derive(self.original, bad)


if __name__ == '__main__': unittest.main()
