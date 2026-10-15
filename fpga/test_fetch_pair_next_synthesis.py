"""Check source export and preserve the guarded native timing lifecycle."""
import json
import unittest

import prepare_fetch_pair_next_synthesis as recipe
import freeze_fetch_pair_next_rk_candidate as freeze
from test_pair_next_disjoint_export import Transfer as ParentTransfer


class Transfer(ParentTransfer):
    def test_frozen_profile_and_three_exact_deltas(self):
        parent = recipe.ROOT/'prefix-payload-fpga-r1'
        candidate = recipe.ROOT/'fetch-pair-next-fpga-r1'
        old = json.loads((parent/'input-manifest.json').read_text())
        new = json.loads((candidate/'input-manifest.json').read_text())
        self.assertEqual(new['hardware_defines'], old['hardware_defines'])
        self.assertEqual(len(new['hardware_defines']), 158)
        self.assertEqual(new['core_mhz'], 40)
        self.assertEqual(new['source_closure'], dict(filelist_units=117, include_edges=49))
        self.assertEqual(new['qualification'], 'UNQUALIFIED')
        self.assertFalse(new['canonical_gate_passed'])
        changes = []
        for row in new['files']:
            name = row['frozen']
            self.assertEqual(recipe.sha(candidate/name), row['sha256'])
            if freeze.check_delta(name, (parent/name).read_bytes(), (candidate/name).read_bytes()):
                changes.append(name)
        self.assertEqual(sorted(changes), freeze.CHANGES)
        self.assertEqual(len(changes), 4)


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n:(recipe.ROOT/n).read_text() for n in recipe.templates.TEMPLATES}
        manifest = json.loads((recipe.ROOT/'fetch-pair-next-fpga-r1/input-manifest.json').read_text())
        changes = {r['frozen']:r['sha256'] for r in manifest['files']
                   if r['frozen'] in manifest['changed_parent_payloads']}
        cls.outputs = recipe.derive(cls.original, changes)

    def test_lifecycle_and_admission_unchanged(self):
        for phase in ('synthesis', 'clock'):
            old = self.original[f'prefix-payload-{phase}-r1/run.py']
            new = self.outputs[f'fetch-pair-next-{phase}-r1/run.py']
            boundary = 'owner = None\n'
            self.assertEqual(old[old.index(boundary):], new[new.index(boundary):])
        old = self.original['prefix-payload-synthesis-r1/run.py']
        new = self.outputs['fetch-pair-next-synthesis-r1/run.py']
        a, b = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)], new[new.index(a):new.index(b)])

    def test_composed_proofs_and_failure_disclosures(self):
        text = self.outputs['fetch-pair-next-synthesis-r1/run.py']
        for item in ('fetch-pair-next-envfault-r1', 'fetch-pair-next-finitecs-r2',
                     'fetch-pair-next-fetch-r1', 'fetch-pair-next-held-r1',
                     'pair-next-disjoint-leaf-r6', 'fetch-fragment-leaf-r5',
                     'canonical 7 PASS/101 FAIL', 'first_v_pairs=72', recipe.AUDIT):
            self.assertIn(item, text)
        self.assertNotIn('fetch-pair-next-leaf-r6', text)
        self.assertNotIn('pair-next-disjoint-core-r1', text)
        self.assertEqual(self.outputs['fetch-pair-next-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])


if __name__ == '__main__':
    unittest.main()
