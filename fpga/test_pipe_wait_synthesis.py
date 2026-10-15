"""Keep exclusive native lifetime/resource bounds and all acceptance evidence."""
import unittest
import prepare_pipe_wait_synthesis as prepare


class Controllers(unittest.TestCase):
    def setUp(self):
        self.templates = {}
        for name, digest in prepare.TEMPLATES.items():
            path = prepare.ROOT/name
            self.assertEqual(prepare.sha(path), digest)
            self.templates[name] = path.read_text()
        path = prepare.ROOT/'pipe-wait-core-r1/candidate'/prepare.native.recipe.FILE
        self.outputs = prepare.derive(self.templates, {'ventium/'+prepare.native.recipe.FILE:prepare.sha(path)})

    def test_exact_lifetime_and_admission(self):
        for phase, revision in (('synthesis', 'r1'), ('clock', 'r2')):
            old = self.templates['demand-size-'+phase+'-'+revision+'/run.py']
            new = self.outputs['pipe-wait-'+phase+'-r1/run.py']
            marker = 'owner = None\n'
            self.assertEqual(old[old.index(marker):], new[new.index(marker):])
            self.assertIn("len(manifest['hardware_defines']) == 159", new)
        old = self.templates['demand-size-synthesis-r1/run.py']
        new = self.outputs['pipe-wait-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])
        for marker in ('native.extended_evidence(proof, core)', 'wait_builder.check_leaf(proof/name)',
                       "len(checked['rows'])==10", "len(checked['rows'])==144",
                       "not verify['canonical_gate_passed']", 'pipe-wait-physical-r1',
                       'pipe-wait-matched-inputs-r1', "prepared['added_defines']==[]"):
            self.assertIn(marker, new)

    def test_resource_mutations_and_extra_source_rejected(self):
        old = self.templates['demand-size-synthesis-r1/run.py']
        new = self.outputs['pipe-wait-synthesis-r1/run.py']
        for a, b in (('memory+swap > 13*gib', 'memory+swap > 14*gib'),
                     ('if free < 4*gib:', 'if free < 1*gib:'),
                     ('native = process.wait(timeout=90)', 'native = 0')):
            with self.assertRaises(AssertionError): prepare.guarded(new.replace(a,b),old)
        with self.assertRaises(AssertionError): prepare.derive(self.templates, {'extra':'x'})

    def test_parent_checkpoint_and_frequency_match(self):
        clock = self.outputs['pipe-wait-clock-r1/run.py']
        self.assertIn(prepare.PARENT_DCP, clock)
        self.assertIn(str(prepare.ROOT/'demand-size-synthesis-r1'), clock)
        self.assertIn('(-2.874)', self.outputs['pipe-wait-clock-r1/audit_closed.py'])
        self.assertEqual(self.outputs['pipe-wait-clock-r1/audit.tcl'],
                         self.templates['demand-size-clock-r2/audit.tcl'])


if __name__ == '__main__':
    unittest.main()
