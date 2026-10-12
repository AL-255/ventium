"""Check source/controller identities and unchanged timing/resource boundaries."""
import unittest

import prepare_next_pair_cofactor_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name,digest in prepare.TEMPLATES.items():
            p = prepare.ROOT/name; assert prepare.sha(p) == digest; cls.original[name] = p.read_text()
        cls.changes = {'ventium/'+p:prepare.sha(prepare.ROOT/'next-pair-cofactor-core-r1/candidate'/p)
                       for p in prepare.native.CHANGES}
        cls.output = prepare.derive(cls.original,cls.changes)

    def test_lifecycle_and_reserves(self):
        for phase in ('synthesis','clock'):
            prepare.guarded(self.output['next-pair-cofactor-'+phase+'-r1/run.py'],
                            self.original['backing-payload-'+phase+'-r1/run.py'])
        text = self.output['next-pair-cofactor-synthesis-r1/run.py']
        for guard in ("VEN_FPGA_JOBS='1'",'free > 6*gib','> 2*measured_disk_growth',"VEN_FPGA_CORE_MHZ='40'"):
            self.assertIn(guard,text)

    def test_exact_change_and_unfiltered_replay(self):
        text = self.output['next-pair-cofactor-synthesis-r1/run.py']
        self.assertIn('changes='+repr(prepare.native.CHANGES),text)
        self.assertIn("load_proof('next-pair-cofactor-replay-r1/closed.json')",text)
        self.assertIn("len(replay['rows'])==108 and replay['records']==80800",text)
        self.assertIn("not verify['canonical_gate_passed']",text)

    def test_parent_and_dma_repair(self):
        text = self.output['next-pair-cofactor-synthesis-r1/audit_closed.py']
        self.assertIn('expected_changes='+repr(self.changes),text)
        self.assertIn(str(prepare.ROOT/'backing-payload-synthesis-r1'),text)
        self.assertIn("assert not re.search(dma_pattern,(old_synth/'runme.log').read_text())",text)
        self.assertIn("assert not re.search(dma_pattern,log)",text)

    def test_best_timing_parent_and_constraints(self):
        text = self.output['next-pair-cofactor-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'memdiv-query-synthesis-r1'),text)
        self.assertIn('(-7.598)',self.output['next-pair-cofactor-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['next-pair-cofactor-clock-r1/audit.tcl'],
                         self.original['backing-payload-clock-r1/audit.tcl'])

    def test_reject_unreviewed_changes(self):
        for bad in ({},dict(self.changes,unreviewed='0'*64)):
            with self.assertRaises(AssertionError): prepare.derive(self.original,bad)


if __name__ == '__main__': unittest.main()
