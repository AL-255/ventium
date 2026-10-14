"""Controller derivation cannot weaken admission, process cleanup or clocks."""
from pathlib import Path
import unittest

import prepare_way_banked_synthesis as recipe


class Controller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in recipe.TEMPLATES.items():
            path=recipe.ROOT/name
            assert recipe.sha(path)==digest
            cls.original[name]=path.read_text()
        cls.output=recipe.derive(cls.original)

    def test_exact_frozen_controllers(self):
        for name,text in self.output.items():
            with self.subTest(name=name):
                self.assertEqual((recipe.ROOT/name).read_text(),text)

    def test_native_guard_lifecycle_unchanged(self):
        for phase,guard in (('synthesis',recipe.guarded),('clock',recipe.clock_guarded)):
            text=self.output[f'way-banked-{phase}-r1/run.py']
            old=self.original[f'fp-compare-{phase}-r1/run.py']
            guard(text,old)
            boundary='owner = None\n'
            self.assertEqual(text[text.index(boundary):],old[old.index(boundary):])
            with self.assertRaises(AssertionError):
                guard(text.replace("VEN_FPGA_CORE_MHZ='40'","VEN_FPGA_CORE_MHZ='30'"),old)
            with self.assertRaises(AssertionError):
                guard(text.replace('if free < 4*gib:','if free < 1*gib:'),old)

    def test_admission_and_read_only_tcl_unchanged(self):
        text=self.output['way-banked-synthesis-r1/run.py']
        old=self.original['fp-compare-synthesis-r1/run.py']
        first,last='host = available()\n',"(root/'once').mkdir()"
        self.assertEqual(text[text.index(first):text.index(last)],old[old.index(first):old.index(last)])
        self.assertEqual(self.output['way-banked-clock-r1/audit.tcl'],
                         self.original['fp-compare-clock-r1/audit.tcl'])

    def test_matched_source_and_complete_proofs_retained(self):
        text=self.output['way-banked-synthesis-r1/run.py']
        for line in ('assert len(prepared[\'intersecting_rtl_sources\'])==102',
                     "assert func['audit_passed'] and func['functional_passes']==108",
                     "assert fetch['passed'] and fetch['cases']==22 and fetch['qemu_comparisons']==88",
                     "assert [r['ticks'] for r in cm['results']]==[4767218,4753406]",
                     "assert not func['canonical_gate_passed'] and not func['physical_board']"):
            self.assertIn(line,text)
        self.assertIn(recipe.PARENT_DCP,self.output['way-banked-clock-r1/run.py'])
        self.assertIn('(-5.859)',self.output['way-banked-clock-r1/audit_closed.py'])


if __name__=='__main__':unittest.main()
