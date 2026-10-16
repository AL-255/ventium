"""Test source transfer and unchanged CAD guards without launching Vivado."""
import unittest

import prepare_sfetch_boundary_timing as p


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        cls.output=p.derive(cls.original)

    def test_sealed_export(self):
        pins=p.evidence.check(p.ROOT/p.SOURCE)
        self.assertIn(str(p.ROOT/p.SOURCE/'input-manifest.json'),pins)

    def test_native_guards_and_mutants(self):
        for phase,key,guard in (('synthesis',p.SYNTH,p.synth_guarded),('clock',p.CLOCK,p.clock_guarded)):
            old=self.original[f'backing-direction-{phase}-r1/run.py'];new=self.output[key+'/run.py']
            guard(new,old)
            for a,b in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                        ('if free < 4*gib:','if free < 1*gib:')):
                with self.assertRaises(AssertionError):guard(new.replace(a,b),old)
            begin,end='host = available()\n',"(root/'once').mkdir()"
            self.assertEqual(old[old.index(begin):old.index(end)],new[new.index(begin):new.index(end)])

    def test_explicit_cost_policy_not_false_equivalence(self):
        run=self.output[p.SYNTH+'/run.py']
        self.assertIn('native.cycle_cost_diagnostic(core)',run)
        self.assertIn("not cycle_policy['cycle_equivalence_passed']",run)
        self.assertIn("0<=r['clock_cost_percent']<=0.2",run)
        self.assertIn('baseline_gameplay_ipc=0.49046518',run)
        self.assertNotIn("all(r['same_records']",run)
        self.assertIn("expected_changes={'ventium/rtl/core/core.sv':",self.output[p.SYNTH+'/audit_closed.py'])
        self.assertEqual(self.output[p.CLOCK+'/audit.tcl'],self.original['backing-direction-clock-r1/audit.tcl'])


if __name__=='__main__':unittest.main()
