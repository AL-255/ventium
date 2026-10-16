"""Test timing source/profile admission and unchanged resource stop policy."""
import unittest

import prepare_next_ready_timing as p


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        cls.output = p.derive(cls.original)

    def test_exact_parent_and_candidate(self):
        run = self.output[p.CLOCK+'/run.py']; audit = self.output[p.SYNTH+'/audit_closed.py']
        self.assertIn('sfetch-boundary-synthesis-r1', run)
        self.assertIn('cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c', run)
        self.assertIn(p.evidence.MANIFEST, run)
        self.assertIn(p.evidence.MODEL, run)
        self.assertIn('sfetch-boundary-fpga-r1', audit)
        self.assertIn(p.evidence.parent_evidence.MANIFEST, audit)
        self.assertIn("expected_changes={'ventium/rtl/mem/ven_l1d.sv':", audit)
        self.assertIn('parent_worst - (-2.050)', self.output[p.CLOCK+'/audit_closed.py'])

    def test_failures_not_waived(self):
        run = self.output[p.SYNTH+'/run.py']
        self.assertIn("all(r['same_records'] for r in verify['deltas'])", run)
        self.assertIn("verify['canonical_gate_native_exit']==2", run)
        self.assertIn("functional['unmasked_functional_passes']==105", run)
        self.assertIn('[4771298,4755366]', run)
        self.assertIn("r['parent_ticks']==r['candidate_ticks']", run)

    def test_guard_mutants_and_unmodified_admission(self):
        for phase, key, guard in (('synthesis',p.SYNTH,p.synth_guarded),('clock',p.CLOCK,p.clock_guarded)):
            old = self.original[f'backing-direction-{phase}-r1/run.py']; new = self.output[key+'/run.py']
            guard(new, old)
            for a,b in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                        ('if free < 4*gib:', 'if free < 1*gib:')):
                with self.assertRaises(AssertionError): guard(new.replace(a,b),old)
            a,b = 'host = available()\n', "(root/'once').mkdir()"
            self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])


if __name__ == '__main__': unittest.main()
