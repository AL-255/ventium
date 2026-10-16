import ast
import inspect
import unittest

import lint_raw_prime_storage_rk as lint
import prepare_raw_prime_storage_timing as p
import run_raw_prime_storage_timing_sequence as sequence


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        cls.output = p.derive(cls.original)

    def test_exact_composition_and_faster_parent(self):
        clock = self.output[p.CLOCK+'/run.py']; audit = self.output[p.SYNTH+'/audit_closed.py']
        for token in ('sfetch-boundary-synthesis-r1',
                      'cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c',
                      p.evidence.MANIFEST,p.evidence.MODEL):
            self.assertIn(token,clock)
        for name in p.evidence.export.CHANGES:
            self.assertIn(name,audit)
        self.assertIn('sfetch-boundary-fpga-r1',audit)
        self.assertIn('parent_worst - (-2.050)',self.output[p.CLOCK+'/audit_closed.py'])
        self.assertIn('isolated_rtl_gain_claimed=False',audit)

    def test_existing_failures_and_mode_preserved(self):
        text = self.output[p.SYNTH+'/run.py']
        for token in ("verify['canonical_gate_native_exit']==2", "all(r['same_records'] for r in verify['deltas'])",
                      "functional['unmasked_functional_passes']==105", 'raw-prime-storage-func-r1/audit.json',
                      'raw-prime-storage-soc-r1/coremark-ui-disabled-r1', '[4771298,4755366]',
                      "r['parent_ticks']==r['candidate_ticks']", 'native.evidence()',
                      "prepared['changes']==[native.recipe.FILE]", 'historical aggregate gates remain failed',
                      'baseline_gameplay_ipc=0.50229051,baseline_window=[1400065247,1500065247]'):
            self.assertIn(token,text)
        self.assertIn('raw_prime_storage_retained_input_unqualified',text)

    def test_guards_and_native_lifecycle_unchanged(self):
        for phase,key,guard in (('synthesis',p.SYNTH,p.synth_guarded),('clock',p.CLOCK,p.clock_guarded)):
            old = self.original[f'prime-width-{phase}-r1/run.py']; new = self.output[key+'/run.py']
            guard(new,old)
            a,b = 'host = available()\n', "(root/'once').mkdir()"
            self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])
            for x,y in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                        ('if free < 4*gib:','if free < 1*gib:')):
                with self.assertRaises(AssertionError): guard(new.replace(x,y),old)

    def test_lint_flags_and_source_lifecycle_unchanged(self):
        text = lint.derive()
        text = text.replace("manifest['variant']==export.VARIANT", "manifest['variant']=='v_result_carry_aux_mouse_unqualified'")
        text = text.replace('Path(previous.__file__),','')
        self.assertEqual(text,inspect.getsource(lint.previous.main))


class Sequence(unittest.TestCase):
    def test_exact_owner_and_original_lifecycle(self):
        old = sequence.previous.derive('0'*32); new = sequence.derive('0'*32)
        a,b = ast.parse(old),ast.parse(new)
        for node in a.body:
            if isinstance(node,ast.FunctionDef):
                peer = next(n for n in b.body if isinstance(n,ast.FunctionDef) and n.name == node.name)
                self.assertEqual(ast.get_source_segment(old,node).replace('prime-width-','raw-prime-storage-'),
                                 ast.get_source_segment(new,peer))
        for phase in ('synth','clock','timing-chain'):
            self.assertIn('ventium-raw-prime-storage-'+phase+'-oct16-r1.service',new)
        for value in ('','a'*31,'A'*32,'a'*33,'a'*31+';'):
            with self.assertRaises(ValueError): sequence.derive(value)


if __name__ == '__main__': unittest.main()
