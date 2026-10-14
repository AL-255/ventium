"""Retain source/proof matching, resource admission and native lifecycle."""
import unittest

import prepare_fast_segment_synthesis as recipe


class Controller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in recipe.TEMPLATES.items():
            path = recipe.ROOT/name
            assert recipe.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.output = recipe.derive(cls.original)

    def test_exact_frozen_controllers(self):
        for name, text in self.output.items():
            with self.subTest(name=name):
                self.assertEqual((recipe.ROOT/name).read_text(), text)

    def test_native_guards_and_cleanup(self):
        for phase, guard in (('synthesis', recipe.guarded), ('clock', recipe.clock_guarded)):
            text = self.output[f'fast-segment-{phase}-r1/run.py']
            old = self.original[f'way-banked-{phase}-r1/run.py']
            guard(text, old)
            for before, after in (("VEN_FPGA_CORE_MHZ='40'", "VEN_FPGA_CORE_MHZ='30'"),
                                  ('if free < 4*gib:', 'if free < 1*gib:')):
                with self.assertRaises(AssertionError):
                    guard(text.replace(before, after), old)

    def test_admission_and_readonly_tcl(self):
        text = self.output['fast-segment-synthesis-r1/run.py']
        old = self.original['way-banked-synthesis-r1/run.py']
        first, last = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(text[text.index(first):text.index(last)], old[old.index(first):old.index(last)])
        self.assertEqual(self.output['fast-segment-clock-r1/audit.tcl'],
                         self.original['way-banked-clock-r1/audit.tcl'])

    def test_exact_parent_proofs_and_current_baseline(self):
        text = self.output['fast-segment-synthesis-r1/run.py']
        for line in (
            "assert len(prepared['intersecting_rtl_sources'])==102",
            "assert func['audit_passed'] and func['functional_passes']==108",
            "assert fetch['passed'] and fetch['cases']==22 and fetch['qemu_comparisons']==88",
            "assert [r['ticks'] for r in cm['results']]==[4767218,4753406]",
            "assert not func['canonical_gate_passed'] and not func['physical_board']",
            "leaf=load_proof('fast-segment-leaf-r1/closed.json')",
            "system=load_proof('fast-segment-system-r2/closed.json')",
            'baseline_gameplay_ipc=0.50607097,baseline_window=[1300065237,1400065237]'):
            self.assertIn(line, text)
        self.assertIn(recipe.PARENT_DCP, self.output['fast-segment-clock-r1/run.py'])
        self.assertIn('(-3.989)', self.output['fast-segment-clock-r1/audit_closed.py'])
        for suffix in ('synthesis-r1', 'fpga-r1'):
            self.assertIn(str(recipe.ROOT/('way-banked-'+suffix)),
                          self.output['fast-segment-synthesis-r1/audit_closed.py'])


if __name__ == '__main__':
    unittest.main()
