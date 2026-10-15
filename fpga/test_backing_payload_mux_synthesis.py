"""Check the exact frozen source delta and unchanged timing-run protections."""
import json
import unittest

import prepare_backing_payload_mux_synthesis as recipe
import freeze_backing_payload_mux_rk_candidate as freeze


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n:(recipe.ROOT/n).read_text() for n in recipe.templates.TEMPLATES}
        cls.source = recipe.ROOT/'backing-payload-mux-fpga-r1'
        cls.manifest = json.loads((cls.source/'input-manifest.json').read_text())
        changes = {n:recipe.sha(cls.source/n) for n in cls.manifest['changed_parent_payloads']}
        cls.outputs = recipe.derive(cls.original, changes)

    def test_exact_export(self):
        old = recipe.ROOT/'prefix-payload-fpga-r1'
        parent = json.loads((old/'input-manifest.json').read_text())
        self.assertEqual(self.manifest['hardware_defines'], parent['hardware_defines'])
        self.assertEqual(len(self.manifest['hardware_defines']), 158)
        self.assertEqual(self.manifest['core_mhz'], 40)
        self.assertEqual(self.manifest['qualification'], 'UNQUALIFIED')
        self.assertFalse(self.manifest['canonical_gate_passed'])
        changed = []
        for row in self.manifest['files']:
            name = row['frozen']
            self.assertEqual(recipe.sha(self.source/name), row['sha256'])
            if freeze.check_delta(name, (old/name).read_bytes(), (self.source/name).read_bytes()):
                changed.append(name)
        self.assertEqual(changed, ['ventium/rtl/mem/ven_l1d.sv'])
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/core/core.sv', b'a', b'b')
        name = changed[0]
        for bad in ((old/name).read_bytes(), (self.source/name).read_bytes()+b'\n'):
            with self.assertRaises(Exception):
                freeze.check_delta(name, (old/name).read_bytes(), bad)

    def test_native_lifecycle_and_admission_unchanged(self):
        for phase in ('synthesis','clock'):
            old = self.original[f'prefix-payload-{phase}-r1/run.py']
            new = self.outputs[f'backing-payload-mux-{phase}-r1/run.py']
            at = 'owner = None\n'
            self.assertEqual(old[old.index(at):], new[new.index(at):])
        old = self.original['prefix-payload-synthesis-r1/run.py']
        new = self.outputs['backing-payload-mux-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])

    def test_new_proofs_not_previous_experiment(self):
        text = self.outputs['backing-payload-mux-synthesis-r1/run.py']
        for item in ('backing-payload-mux-cache-r2', 'backing-payload-mux-leaf-r1',
                     'backing-payload-mux-freshfunc-r1', 'backing-payload-mux-system-r1',
                     'backing-payload-mux-held-r1', 'canonical 7 PASS/101 FAIL', recipe.AUDIT):
            self.assertIn(item, text)
        self.assertNotIn('pair-next-disjoint-', text)
        self.assertNotIn("func['authenticated_input_replay']", text)
        self.assertEqual(self.outputs['backing-payload-mux-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])


if __name__ == '__main__':
    unittest.main()
