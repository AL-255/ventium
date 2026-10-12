"""Controller-identity and unchanged safety/clock checks, without running Vivado."""
import re
import unittest

import prepare_backing_pair_payload_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in prepare.TEMPLATES.items():
            p=prepare.ROOT/name;assert prepare.sha(p)==digest;cls.original[name]=p.read_text()
        cls.changes={'ventium/'+p:prepare.sha(prepare.ROOT/'backing-payload-core-r1/candidate'/p)
                     for p in prepare.native.CHANGES}
        cls.output=prepare.derive(cls.original,cls.changes)

    def test_resource_lifecycle_and_clock_unchanged(self):
        for phase in ('synthesis','clock'):
            old=self.original['fp-high-valid-'+phase+'-r1/run.py']
            new=self.output['backing-payload-'+phase+'-r1/run.py']
            prepare.guarded(new,old)
            self.assertEqual(new[new.index('owner = None\n'):],old[old.index('owner = None\n'):])
        text=self.output['backing-payload-synthesis-r1/run.py']
        for guard in ("VEN_FPGA_JOBS='1'",'free > 6*gib','> 2*measured_disk_growth',"VEN_FPGA_CORE_MHZ='40'"):
            self.assertIn(guard,text)

    def test_two_source_files_and_complete_replay(self):
        text=self.output['backing-payload-synthesis-r1/run.py']
        self.assertIn('changes='+repr(prepare.native.CHANGES),text)
        self.assertIn("load_proof('backing-payload-regressions-r1/replay/closed.json')",text)
        self.assertIn("not verify['canonical_gate_passed']",text)
        self.assertIn('expected_changes='+repr(self.changes),self.output['backing-payload-synthesis-r1/audit_closed.py'])

    def test_best_parent_retained(self):
        self.assertIn(str(prepare.ROOT/'memdiv-query-synthesis-r1'),self.output['backing-payload-clock-r1/run.py'])
        self.assertIn('(-7.598)',self.output['backing-payload-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['backing-payload-clock-r1/audit.tcl'],self.original['fp-high-valid-clock-r1/audit.tcl'])

    def test_dma_diagnostic_gate_matches_actual_old_warnings(self):
        text=self.output['backing-payload-synthesis-r1/audit_closed.py']
        pattern=re.search(r"dma_pattern=r'(.*)'",text)[1]
        old=(prepare.ROOT/'fp-high-valid-synthesis-r1/native-synthesis/rk_ao486_system/rk_ao486_system.runs/synth_1/runme.log').read_text()
        self.assertEqual(set(re.findall(pattern,old)),{(str(c),n) for c in range(4) for n in ('reset','flip_flop')})
        self.assertIn("assert not re.search(dma_pattern,log)",text)

    def test_reject_missing_or_extra_changes(self):
        for bad in ({},dict(self.changes,unreviewed='0'*64)):
            with self.assertRaises(AssertionError):prepare.derive(self.original,bad)


if __name__=='__main__':unittest.main()
