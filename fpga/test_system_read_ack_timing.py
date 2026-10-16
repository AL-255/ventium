"""Host checks for exact parent comparison and unchanged guarded lifecycle."""
import ast
import unittest

import prepare_system_read_ack_timing as timing
import lint_system_read_ack_rk as lint


class TimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in timing.TEMPLATES.items():
            path=timing.ROOT/name
            assert timing.sha(path)==digest
            cls.original[name]=path.read_text()
        cls.output=timing.derive(cls.original)

    def test_resource_lifecycle_and_tcl_unchanged(self):
        for phase,folder in (('synthesis',timing.SYNTH),('clock',timing.CLOCK)):
            old=self.original['raw-prime-storage-'+phase+'-r1/run.py']
            new=self.output[folder+'/run.py']
            mark='owner = None\n'
            self.assertEqual(new[new.index(mark):],old[old.index(mark):])
            a,b='host = available()\n',"(root/'once').mkdir()"
            self.assertEqual(new[new.index(a):new.index(b)],old[old.index(a):old.index(b)])
            tcl='launch_checked.tcl' if phase=='synthesis' else 'audit.tcl'
            self.assertEqual(self.output[folder+'/'+tcl],self.original['raw-prime-storage-'+phase+'-r1/'+tcl])

    def test_same_input_proof_not_inherited_private_gate(self):
        run=self.output[timing.SYNTH+'/run.py']
        self.assertIn("len(functional['rows'])==128",run)
        self.assertIn("functional['native_gate_exit']==2 and not functional['canonical_gate_passed']",run)
        self.assertIn("prepared['changes']==native.CHANGES",run)
        self.assertIn('native.recipe.transform(before,name.removeprefix(native.recipe.PREFIX))',run)
        self.assertNotIn('unmasked_functional_passes',run)
        self.assertNotIn('105 unmasked',run)

    def test_exact_immediate_parent_and_no_acceptance(self):
        for name,source in self.output.items():
            if name.endswith('.py'):
                ast.parse(source)
                self.assertNotIn('sfetch-boundary-',source)
        synth=self.output[timing.SYNTH+'/audit_closed.py']
        self.assertIn('raw-prime-storage-fpga-r1',synth)
        self.assertIn(timing.evidence.export.PARENT,synth)
        clock=self.output[timing.CLOCK+'/run.py']
        self.assertIn('raw-prime-storage-synthesis-r1',clock)
        self.assertIn(timing.PARENT_DCP,clock)
        self.assertIn('hardware_acceptance=False',clock)
        self.assertIn('parent_worst - (-3.269)',self.output[timing.CLOCK+'/audit_closed.py'])
        module=ast.parse(synth)
        changes=[ast.literal_eval(n.value) for n in module.body if isinstance(n,ast.Assign)
                 and any(isinstance(t,ast.Name) and t.id=='expected_changes' for t in n.targets)]
        self.assertEqual(len(changes),1)
        self.assertEqual(sorted(changes[0]),timing.evidence.export.CHANGES)

    def test_lint_keeps_native_policy(self):
        source=lint.derive()
        self.assertIn("manifest['variant']==export.VARIANT",source)
        self.assertIn('assert recovered==original.read_text()',source)
        self.assertIn('return status',source)


if __name__=='__main__':unittest.main()
