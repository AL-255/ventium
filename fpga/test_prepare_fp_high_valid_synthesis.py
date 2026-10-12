"""Audit controller derivation against the exact already-closed templates."""
import unittest

import prepare_fp_high_valid_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in prepare.TEMPLATES.items():
            path=prepare.ROOT/name
            assert prepare.sha(path)==digest
            cls.original[name]=path.read_text()
        cls.changes={'ventium/'+name:prepare.sha(prepare.ROOT/'fp-high-valid-core-r1/candidate'/name)
                     for name in prepare.native.CHANGES}
        cls.output=prepare.derive(cls.original,cls.changes)

    def test_lifecycle_is_identical(self):
        for phase in ('synthesis','clock'):
            old=self.original['pair-now-read-'+phase+'-r1/run.py']
            new=self.output['fp-high-valid-'+phase+'-r1/run.py']
            prepare.guarded(new,old)
            self.assertEqual(new[new.index('owner = None\n'):],old[old.index('owner = None\n'):])
            for guard in ("VEN_FPGA_JOBS='1'", "VEN_FPGA_CORE_MHZ='40'", "'128'"):
                if guard in old: self.assertIn(guard,new)

    def test_three_files_and_actual_replay(self):
        text=self.output['fp-high-valid-synthesis-r1/run.py']
        self.assertIn('changes='+repr(prepare.native.CHANGES),text)
        self.assertIn("load_proof('fp-high-valid-regressions-r2/replay/closed.json')",text)
        self.assertIn('not verify[\'canonical_gate_passed\']',text)
        audit=self.output['fp-high-valid-synthesis-r1/audit_closed.py']
        self.assertIn('expected_changes='+repr(self.changes),audit)
        self.assertIn(str(prepare.ROOT/'pair-now-read-fpga-r1'),audit)

    def test_timing_compares_best_checkpoint_not_regressed_source_parent(self):
        text=self.output['fp-high-valid-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'memdiv-query-synthesis-r1'),text)
        self.assertIn('58069b79e9e9c52ba93a5ce4a528e0aae96b478ba5ac8a02c0b9fca084f3ea1b',text)
        self.assertIn('(-7.598)',self.output['fp-high-valid-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['fp-high-valid-clock-r1/audit.tcl'],
                         self.original['pair-now-read-clock-r1/audit.tcl'])

    def test_no_extra_or_missing_source_delta(self):
        with self.assertRaises(AssertionError): prepare.derive(self.original,{})
        with self.assertRaises(AssertionError):
            prepare.derive(self.original,dict(self.changes,unreviewed='0'*64))


if __name__=='__main__': unittest.main()
