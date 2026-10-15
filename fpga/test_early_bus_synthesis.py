"""Check exact controller lifecycle and reject relaxed safety controls."""
import unittest
import prepare_early_bus_synthesis as prepare


class Controllers(unittest.TestCase):
    def setUp(self):
        self.templates = {}
        for name, digest in prepare.TEMPLATES.items():
            p = prepare.ROOT/name
            self.assertEqual(prepare.sha(p), digest)
            self.templates[name] = p.read_text()
        self.outputs = prepare.derive(self.templates, {'ventium/'+prepare.native.recipe.FILE:
            '1b67761e014321884d87099df3cc1c4b3d834b40acf83fb58cf6d68b02ead818'})

    def test_lifetime_and_admission_unchanged(self):
        for phase in ('synthesis', 'clock'):
            old = self.templates['decode-bus-'+phase+'-r1/run.py']
            new = self.outputs['early-bus-'+phase+'-r1/run.py']
            anchor = 'owner = None\n'
            self.assertEqual(old[old.index(anchor):], new[new.index(anchor):])
            self.assertIn("len(manifest['hardware_defines']) == 159", new)
        old = self.templates['decode-bus-synthesis-r1/run.py']
        new = self.outputs['early-bus-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])
        for expected in ("len(checked['rows'])==144", "not verify['canonical_gate_passed']",
                         'early-bus-matched-inputs-r1', 'early-bus-physical-r2',
                         "prepared['added_defines']==[]"):
            self.assertIn(expected, new)

    def test_mutations_and_extra_source_rejected(self):
        old = self.templates['decode-bus-synthesis-r1/run.py']
        new = self.outputs['early-bus-synthesis-r1/run.py']
        for a, b in (('memory+swap > 13*gib', 'memory+swap > 14*gib'),
                     ('if free < 4*gib:', 'if free < 1*gib:'),
                     ('native = process.wait(timeout=90)', 'native = 0')):
            self.assertIn(a, new)
            with self.assertRaises(AssertionError): prepare.guarded(new.replace(a, b), old)
        with self.assertRaises(AssertionError): prepare.derive(self.templates, {'unreviewed': 'x'})


if __name__ == '__main__': unittest.main()
