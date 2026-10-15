"""Guard-preserving timing derivation and exact source/proof bindings."""
import json
import unittest

import prepare_fetch_metadata_synthesis as recipe


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(recipe.ROOT/n).read_text() for n in recipe.templates.TEMPLATES}
        manifest=json.loads((recipe.ROOT/'fetch-metadata-fpga-r1/input-manifest.json').read_text())
        cls.changes={r['frozen']:r['sha256'] for r in manifest['files']
                     if r['frozen'] in manifest['changed_parent_payloads']}
        cls.outputs=recipe.derive(cls.original,cls.changes)

    def test_native_lifecycle_unchanged(self):
        for phase in ('synthesis','clock'):
            old=self.original[f'prefix-payload-{phase}-r1/run.py']
            new=self.outputs[f'fetch-metadata-{phase}-r1/run.py']
            boundary='owner = None\n'
            self.assertEqual(old[old.index(boundary):],new[new.index(boundary):])

    def test_admission_and_mapper_unchanged(self):
        old=self.original['prefix-payload-synthesis-r1/run.py']
        new=self.outputs['fetch-metadata-synthesis-r1/run.py']
        a,b='host = available()\n',"(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])
        for value in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'memory+swap > 13*gib','if free < 4*gib:',"VEN_FPGA_CORE_MHZ='40'",
                      "VEN_FPGA_BUILD_PROFILE='logic_only'"):
            self.assertIn(value,new)

    def test_current_proofs_and_all_repairs(self):
        new=self.outputs['fetch-metadata-synthesis-r1/run.py']
        for required in ("func['input_pins']==1454",'native.FP_AUDIT',
                         "not verify['canonical_gate_passed']",
                         "cmroot=root.parent/'fetch-metadata-soc-r1/coremark-r1'"):
            self.assertIn(required,new)
        self.assertNotIn('regression-audit.json',new)
        self.assertNotIn('env-fault-r1',new)
        self.assertEqual(len(self.changes),3)
        partial=dict(self.changes);partial.pop('ventium/fp_shared/ven_fp_top.sv')
        with self.assertRaises(AssertionError):recipe.derive(self.original,partial)

    def test_clock_tcl_identical_and_parent_pinned(self):
        self.assertEqual(self.outputs['fetch-metadata-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])
        self.assertIn(recipe.PARENT_DCP,self.outputs['fetch-metadata-clock-r1/run.py'])
        self.assertIn('(-2.329)',self.outputs['fetch-metadata-clock-r1/audit_closed.py'])


if __name__=='__main__':unittest.main()
