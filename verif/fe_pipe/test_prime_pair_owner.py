#!/usr/bin/env python3
"""Host guard tests; not substitutes for native RTL/QEMU qualification."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepare',HERE/'prepare-prime-pair-owner.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR','/tmp'))
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.source=self.root/'source'
        path=self.source/'rtl/mem/ven_l1d.sv';path.parent.mkdir(parents=True)
        path.write_text('module witness;\n'
            '  assign pair_legacy_overlap = c_req && !c_we && rd_match && c_ack && cacheable;\n'
            'endmodule\n')
        (self.source/'untouched.txt').write_text('keep\n')

    def test_one_leaf_only_and_core_profile_only(self):
        output=self.root/'candidate'
        prepare.prepare(self.source,output)
        text=(output/'rtl/mem/ven_l1d.sv').read_text()
        self.assertIn('`ifdef VEN_P54_DUAL_LOAD_PAIR',text)
        self.assertIn("&& (pair_req_valid != 2'b10)",text)
        self.assertIn('rd_match && c_ack && cacheable',text)
        pins=json.loads((output/'prime-pair-owner-inputs.json').read_text())
        self.assertEqual([p for p in pins['parent_pins']
                          if pins['parent_pins'][p]!=pins['candidate_pins'][p]],['rtl/mem/ven_l1d.sv'])
        self.assertEqual((output/'untouched.txt').read_text(),'keep\n')
        self.assertFalse(pins['standard_suite'])
        self.assertIsNone(pins['gameplay_ipc'])

    def test_reject_nested_copy(self):
        with self.assertRaises(AssertionError):
            prepare.prepare(self.source,self.source/'nested')
        self.assertFalse((self.source/'nested').exists())

    def test_reject_reapplication(self):
        output=self.root/'candidate'
        prepare.prepare(self.source,output)
        with self.assertRaises(AssertionError):
            prepare.prepare(output,self.root/'again')

    def test_reject_anchor_drift(self):
        path=self.source/'rtl/mem/ven_l1d.sv'
        path.write_text(path.read_text().replace(' && c_ack',''))
        with self.assertRaises(AssertionError):
            prepare.prepare(self.source,self.root/'candidate')


if __name__=='__main__': unittest.main()
