"""Keep the proven resource lifecycle and distinct source/timing controls."""
import unittest

import prepare_fresh_pair_synthesis as prepare


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in prepare.TEMPLATES.items():
            path=prepare.ROOT/name
            assert prepare.sha(path)==digest
            cls.original[name]=path.read_text()
        cls.changes={'ventium/'+n:prepare.sha(prepare.ROOT/'fresh-pair-core-r1/candidate'/n)
                     for n in prepare.native.CHANGES}
        cls.output=prepare.derive(cls.original,cls.changes)

    def test_resource_lifecycle_and_original_clocks(self):
        for phase in ('synthesis','clock'):
            text=self.output['fresh-pair-'+phase+'-r1/run.py']
            prepare.guarded(text,self.original['read-owner-'+phase+'-r1/run.py'])
            for guard in ("VEN_FPGA_JOBS='1'","VEN_FPGA_CORE_MHZ='40'",
                          "VEN_FPGA_BUILD_PROFILE='logic_only'",'min(host.values()) < 2*gib'):
                self.assertIn(guard,text)
        text=self.output['fresh-pair-synthesis-r1/run.py']
        for guard in ('free > 6*gib','> 2*measured_disk_growth','disk_stop_floor=4*gib'):
            self.assertIn(guard,text)

    def test_full_evidence_required(self):
        text=self.output['fresh-pair-synthesis-r1/run.py']
        for marker in ("load_proof('fresh-pair-regressions-r1/closed.json')",
                       "len(reg['rows'])==12","len(fp['measurements'])==1536",
                       "len(fp['deltas'])==768","all(r['saved_clocks']==0 for r in fp['deltas'])",
                       "len(replay['rows'])==108 and replay['records']==80800",
                       "not verify['canonical_gate_passed']","[4767218,4753406]",
                       prepare.native.CORE_MODEL):
            self.assertIn(marker,text)

    def test_source_parent_and_only_one_payload_delta(self):
        text=self.output['fresh-pair-synthesis-r1/audit_closed.py']
        self.assertIn(str(prepare.ROOT/'read-owner-synthesis-r1'),text)
        self.assertIn(str(prepare.ROOT/'read-owner-fpga-r1'),text)
        self.assertIn(prepare.PARENT_MANIFEST,text)
        self.assertEqual(list(self.changes),['ventium/rtl/mem/ven_l1d.sv'])
        self.assertIn('expected_changes='+repr(self.changes),text)
        self.assertIn("assert manifest['hardware_defines'] == old_manifest['hardware_defines']",text)

    def test_best_timing_control_not_regressed_source_parent(self):
        text=self.output['fresh-pair-clock-r1/run.py']
        self.assertIn(str(prepare.ROOT/'pair-intent-synthesis-r1'),text)
        self.assertIn(prepare.BEST_DCP,text)
        self.assertIn('(-6.594)',self.output['fresh-pair-clock-r1/audit_closed.py'])
        self.assertEqual(self.output['fresh-pair-clock-r1/audit.tcl'],
                         self.original['read-owner-clock-r1/audit.tcl'])

    def test_reject_unreviewed_payloads(self):
        for bad in ({},dict(self.changes,unreviewed='0'*64)):
            with self.assertRaises(AssertionError):prepare.derive(self.original,bad)


if __name__=='__main__':unittest.main()
