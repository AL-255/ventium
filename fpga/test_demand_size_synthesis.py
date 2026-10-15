"""Preserve exclusive Vivado lifetime/resource controls and the real evidence gates."""
import unittest
import prepare_demand_size_synthesis as prepare


class Controllers(unittest.TestCase):
    def setUp(self):
        self.templates = {}
        for name, digest in prepare.TEMPLATES.items():
            p = prepare.ROOT/name
            self.assertEqual(prepare.sha(p), digest)
            self.templates[name] = p.read_text()
        path = prepare.ROOT/'demand-size-core-r1/candidate'/prepare.native.recipe.FILE
        self.outputs = prepare.derive(self.templates, {'ventium/'+prepare.native.recipe.FILE: prepare.sha(path)})

    def test_lifetime_admission_and_evidence(self):
        for phase in ('synthesis', 'clock'):
            old = self.templates['early-bus-'+phase+'-r1/run.py']
            new = self.outputs['demand-size-'+phase+'-r1/run.py']
            anchor = 'owner = None\n'
            self.assertEqual(old[old.index(anchor):], new[new.index(anchor):])
            self.assertIn("len(manifest['hardware_defines']) == 159", new)
        old = self.templates['early-bus-synthesis-r1/run.py']
        new = self.outputs['demand-size-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])
        for required in ("len(checked['rows'])==144", "not verify['canonical_gate_passed']",
                         'demand-size-matched-inputs-r1', 'demand-size-physical-r1',
                         'demand_builder.check_leaf(proof/name)', "prepared['added_defines']==[]"):
            self.assertIn(required, new)

    def test_mutated_controls_and_extra_source_rejected(self):
        old = self.templates['early-bus-synthesis-r1/run.py']
        new = self.outputs['demand-size-synthesis-r1/run.py']
        for a, b in (('memory+swap > 13*gib', 'memory+swap > 14*gib'),
                     ('if free < 4*gib:', 'if free < 1*gib:'),
                     ('native = process.wait(timeout=90)', 'native = 0')):
            self.assertIn(a, new)
            with self.assertRaises(AssertionError):
                prepare.guarded(new.replace(a, b), old)
        with self.assertRaises(AssertionError):
            prepare.derive(self.templates, {'unreviewed': 'x'})


if __name__ == '__main__':
    unittest.main()
