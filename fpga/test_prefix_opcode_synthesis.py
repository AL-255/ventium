"""Candidate identities must not relax the native timing/resource guards."""
import unittest

import prepare_prefix_opcode_synthesis as recipe


class Controller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in recipe.TEMPLATES.items():
            path = recipe.ROOT/name
            assert recipe.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.output = recipe.derive(cls.original)

    def test_native_guards_and_cleanup(self):
        for phase, guard in (('synthesis', recipe.guarded), ('clock', recipe.clock_guarded)):
            text = self.output[f'prefix-opcode-{phase}-r1/run.py']
            old = self.original[f'prefix-payload-{phase}-r1/run.py']
            guard(text, old)
            for before, after in (("VEN_FPGA_CORE_MHZ='40'", "VEN_FPGA_CORE_MHZ='30'"),
                                  ('if free < 4*gib:', 'if free < 1*gib:')):
                with self.assertRaises(AssertionError):
                    guard(text.replace(before, after), old)

    def test_admission_and_readonly_tcl(self):
        text = self.output['prefix-opcode-synthesis-r1/run.py']
        old = self.original['prefix-payload-synthesis-r1/run.py']
        first, last = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(text[text.index(first):text.index(last)], old[old.index(first):old.index(last)])
        self.assertEqual(self.output['prefix-opcode-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])

    def test_exact_proofs_and_no_failure_promotion(self):
        text = self.output['prefix-opcode-synthesis-r1/run.py']
        for line in (
            "assert len(prepared['intersecting_rtl_sources'])==102",
            "assert func['audit_passed'] and func['functional_passes']==108",
            "assert fetch['passed'] and fetch['cases']==22 and fetch['qemu_comparisons']==88",
            "assert [r['ticks'] for r in cm['results']]==[4767218,4753406]",
            "assert not func['canonical_gate_passed'] and not func['physical_board']",
            "fault=load_proof('prefix-opcode-env-fault-r1/closed.json')",
            "leaf=load_proof('prefix-opcode-leaf-r2/closed.json')",
            "assert leaf['checks']==2752512 and leaf['outputs']==122",
            "assert [r['exit'] for r in leaf['native']]==[0,0,1,1]",
            "system=load_proof('prefix-opcode-system-r1/closed.json')",
            "boundary=load_proof('prefix-payload-boundary-r1/closed.json')",
            "assert not boundary['passed'] and boundary['errors']",
            'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'):
            self.assertIn(line, text)
        self.assertIn(recipe.PARENT_DCP, self.output['prefix-opcode-clock-r1/run.py'])
        self.assertIn('(-2.329)', self.output['prefix-opcode-clock-r1/audit_closed.py'])
        for phase in ('synth','clock'):
            self.assertIn(f'ventium-prefix-opcode-{phase}-oct15-r1.service',
                          self.output[f'prefix-opcode-{"synthesis" if phase=="synth" else phase}-r1/audit_closed.py'])
        for suffix in ('synthesis-r1', 'fpga-r1'):
            self.assertIn(str(recipe.ROOT/('prefix-payload-'+suffix)),
                          self.output['prefix-opcode-synthesis-r1/audit_closed.py'])


if __name__ == '__main__': unittest.main()
