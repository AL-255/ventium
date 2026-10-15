"""Prove controller adaptation retains ownership, stop floors and native wait."""
import unittest
import prepare_decode_bus_synthesis as prepare


class Controllers(unittest.TestCase):
    def setUp(self):
        self.templates = {}
        for name, digest in prepare.TEMPLATES.items():
            p = prepare.ROOT/name
            self.assertEqual(prepare.sha(p), digest)
            self.templates[name] = p.read_text()
        self.outputs = prepare.derive(self.templates, {'ventium/'+prepare.native.recipe.FILE:
            '4bb63e3a106284c1c1e07aa91f35bd72a8ac25475bd402c5eeb2b0f30a7d9426'})

    def test_lifetime_and_admission_unchanged(self):
        for phase in ('synthesis', 'clock'):
            old = self.templates['branch-address-'+phase+'-r1/run.py']
            new = self.outputs['decode-bus-'+phase+'-r1/run.py']
            anchor = 'owner = None\n'
            self.assertEqual(old[old.index(anchor):], new[new.index(anchor):])
            self.assertIn("len(manifest['hardware_defines']) == 159", new)
            self.assertIn('candidate_gameplay_ipc=None', new)
        old = self.templates['branch-address-synthesis-r1/run.py']
        new = self.outputs['decode-bus-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])
        self.assertIn('len(checked[\'rows\'])==144', new)
        self.assertIn('not verify[\'canonical_gate_passed\']', new)

    def test_guard_mutations_and_extra_source_rejected(self):
        old = self.templates['branch-address-synthesis-r1/run.py']
        new = self.outputs['decode-bus-synthesis-r1/run.py']
        for a, b in (('memory+swap > 13*gib', 'memory+swap > 14*gib'),
                     ('if free < 4*gib:', 'if free < 1*gib:'),
                     ('native = process.wait(timeout=90)', 'native = 0')):
            self.assertIn(a, new)
            with self.assertRaises(AssertionError): prepare.guarded(new.replace(a, b), old)
        with self.assertRaises(AssertionError): prepare.derive(self.templates, {'unreviewed': 'x'})


if __name__ == '__main__':
    unittest.main()
