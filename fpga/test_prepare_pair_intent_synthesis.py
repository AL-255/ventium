"""Guard the four-file core / five-file PC split and unchanged native bounds."""
import unittest

import prepare_pair_intent_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in prepare.TEMPLATES.items():
            path = prepare.ROOT/name
            assert prepare.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.changes = {'ventium/'+p: prepare.sha(prepare.ROOT/'pair-intent-core-r1/candidate'/p)
                       for p in prepare.native.CHANGES}
        cls.output = prepare.derive(cls.original, cls.changes)

    def test_lifecycle_and_reserves(self):
        for phase in ('synthesis', 'clock'):
            prepare.guarded(self.output['pair-intent-'+phase+'-r1/run.py'],
                            self.original['backing-payload-'+phase+'-r1/run.py'])
        text = self.output['pair-intent-synthesis-r1/run.py']
        for guard in ("VEN_FPGA_JOBS='1'", 'free > 6*gib', '> 2*measured_disk_growth',
                      "VEN_FPGA_CORE_MHZ='40'"):
            self.assertIn(guard, text)

    def test_exact_profiles_and_replay(self):
        text = self.output['pair-intent-synthesis-r1/run.py']
        self.assertIn('changes='+repr(sorted(prepare.native.recipe.PARENTS)), text)
        self.assertIn("prepared['changes']=="+repr(prepare.native.CHANGES), text)
        self.assertEqual(len(prepare.native.CHANGES), 5)
        self.assertIn("load_proof('pair-intent-replay-r1/closed.json')", text)
        self.assertIn("len(replay['rows'])==108 and replay['records']==80800", text)
        self.assertIn("not verify['canonical_gate_passed']", text)
        self.assertIn(prepare.native.CORE_MODEL, text)

    def test_parent_and_dma_repair(self):
        text = self.output['pair-intent-synthesis-r1/audit_closed.py']
        self.assertIn('expected_changes='+repr(self.changes), text)
        self.assertIn(str(prepare.ROOT/'backing-payload-synthesis-r1'), text)
        self.assertIn("assert not re.search(dma_pattern,(old_synth/'runme.log').read_text())", text)
        self.assertIn("assert not re.search(dma_pattern,log)", text)

    def test_best_parent_original_constraints(self):
        text = self.output['pair-intent-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'memdiv-query-synthesis-r1'), text)
        self.assertIn('(-7.598)', self.output['pair-intent-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['pair-intent-clock-r1/audit.tcl'],
                         self.original['backing-payload-clock-r1/audit.tcl'])

    def test_reject_unreviewed_changes(self):
        for bad in ({}, dict(self.changes, unreviewed='0'*64)):
            with self.assertRaises(AssertionError):
                prepare.derive(self.original, bad)


if __name__ == '__main__':
    unittest.main()
