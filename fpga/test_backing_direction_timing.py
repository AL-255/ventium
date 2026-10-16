"""Check exact transfer and CAD guards; none of these tests launch Vivado."""
import unittest

import prepare_backing_direction_timing as p


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        cls.output=p.derive(cls.original)

    def test_sealed_export_and_closed_lint(self):
        pins=p.evidence.check(p.ROOT/p.SOURCE)
        self.assertIn(str(p.ROOT/p.SOURCE/'input-manifest.json'),pins)
        lint=p.evidence.native.load(p.ROOT/'backing-direction-lint-r1/closed.json')
        self.assertTrue(lint['passed'] and lint['inputs_unchanged'])
        self.assertEqual(lint['source_manifest_sha256'],p.evidence.MANIFEST)
        self.assertFalse(lint['full_soc_lint'])

    def test_generated_outputs_exact_and_parseable(self):
        for n,s in self.output.items():
            self.assertEqual(s,(p.ROOT/n).read_text())
            if n.endswith('.py'):compile(s,n,'exec')
        self.assertEqual(self.output[p.CLOCK+'/audit.tcl'],self.original['posted-mouse-clock-r1/audit.tcl'])

    def test_resource_guards_and_mutants(self):
        for phase,key,guard in (('synthesis',p.SYNTH,p.synth_guarded),('clock',p.CLOCK,p.clock_guarded)):
            old=self.original[f'posted-mouse-{phase}-r1/run.py'];new=self.output[key+'/run.py']
            guard(new,old)
            for a,b in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                        ('if free < 4*gib:','if free < 1*gib:')):
                with self.assertRaises(AssertionError):guard(new.replace(a,b),old)

    def test_single_delta_and_canonical_failure_preserved(self):
        run=self.output[p.SYNTH+'/run.py'];audit=self.output[p.SYNTH+'/audit_closed.py']
        for text in ("verify['canonical_gate_native_exit']==2",'pins.update(native.evidence(proof,core))',
                     "cm_audit['no_oom']",'baseline_gameplay_ipc=0.48146083'):
            self.assertIn(text,run)
        self.assertIn('assert set(new_rows)==set(old_rows)',audit)
        self.assertIn("expected_changes={'ventium/rtl/mem/ven_l1d.sv':",audit)
        self.assertIn("parent_worst - (-3.858)",self.output[p.CLOCK+'/audit_closed.py'])


if __name__=='__main__':unittest.main()
