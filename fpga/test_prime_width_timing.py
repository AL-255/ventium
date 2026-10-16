import ast
import unittest

import prepare_prime_width_timing as p
import run_prime_width_timing_sequence as sequence


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        cls.output=p.derive(cls.original)

    def test_exact_parent_candidate_and_width_delta(self):
        run=self.output[p.CLOCK+'/run.py'];audit=self.output[p.SYNTH+'/audit_closed.py']
        for token in ('sfetch-boundary-synthesis-r1',
                      'cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c',
                      p.evidence.MANIFEST,p.evidence.MODEL):
            self.assertIn(token,run)
        self.assertIn('sfetch-boundary-fpga-r1',audit)
        self.assertIn("expected_changes={'ventium/rtl/core/core_mem_chain.svh':",audit)
        self.assertIn('parent_worst - (-2.050)',self.output[p.CLOCK+'/audit_closed.py'])

    def test_failed_gates_and_unchanged_controls_remain_explicit(self):
        run=self.output[p.SYNTH+'/run.py']
        for token in ("all(r['same_records'] for r in verify['deltas'])",
                      "verify['canonical_gate_native_exit']==2",'prime-width-func-r2/audit.json',
                      "functional['unmasked_functional_passes']==105",'[4771298,4755366]',
                      "r['parent_ticks']==r['candidate_ticks']",'Historical counter gate remains failed',
                      'baseline_gameplay_ipc=0.51045343,baseline_window=[1200065247,1300065247]',
                      "baseline_model='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'"):
            self.assertIn(token,run)
        self.assertNotIn('binary proof',run)

    def test_resource_admission_and_guard_mutants(self):
        for phase,key,guard in (('synthesis',p.SYNTH,p.synth_guarded),('clock',p.CLOCK,p.clock_guarded)):
            old=self.original[f'backing-direction-{phase}-r1/run.py'];new=self.output[key+'/run.py']
            guard(new,old)
            for a,b in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                        ('if free < 4*gib:','if free < 1*gib:')):
                with self.assertRaises(AssertionError):guard(new.replace(a,b),old)
            a,b='host = available()\n',"(root/'once').mkdir()"
            self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])


class Sequence(unittest.TestCase):
    def test_exact_owner_and_unchanged_lifecycle(self):
        old=sequence.previous.derive('0'*32);new=sequence.derive('0'*32)
        a,b=ast.parse(old),ast.parse(new)
        for node in a.body:
            if isinstance(node,ast.FunctionDef):
                match=next(n for n in b.body if isinstance(n,ast.FunctionDef) and n.name==node.name)
                self.assertEqual(ast.get_source_segment(old,node).replace('sfetch-interior-','prime-width-'),
                                 ast.get_source_segment(new,match))
        for phase in ('synth','clock','timing-chain'):
            self.assertIn('ventium-prime-width-'+phase+'-oct16-r1.service',new)
        for value in ('','a'*31,'A'*32,'a'*33,'a'*31+';'):
            with self.assertRaises(ValueError):sequence.derive(value)


if __name__=='__main__':unittest.main()
