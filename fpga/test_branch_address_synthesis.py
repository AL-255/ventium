import json
import unittest

import prepare_branch_address_synthesis as recipe


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(recipe.DATA/n).read_text() for n in recipe.templates.TEMPLATES}
        m=json.loads((recipe.ROOT/'branch-address-fpga-r1/input-manifest.json').read_text())
        cls.changes={r['frozen']:r['sha256'] for r in m['files'] if r['frozen'] in m['changed_parent_payloads']}
        cls.outputs=recipe.derive(cls.original,cls.changes)

    def test_native_lifecycle_and_admission_unchanged(self):
        for phase in ('synthesis','clock'):
            old=self.original[f'prefix-payload-{phase}-r1/run.py']
            new=self.outputs[f'branch-address-{phase}-r1/run.py']
            boundary='owner = None\n'
            self.assertEqual(old[old.index(boundary):],new[new.index(boundary):])
        old=self.original['prefix-payload-synthesis-r1/run.py'];new=self.outputs['branch-address-synthesis-r1/run.py']
        a,b='host = available()\n',"(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])
        for value in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'memory+swap > 13*gib','if free < 4*gib:',"VEN_FPGA_CORE_MHZ='40'",
                      "VEN_FPGA_BUILD_PROFILE='logic_only'"):
            self.assertIn(value,new)

    def test_current_proofs_and_complete_transfer(self):
        new=self.outputs['branch-address-synthesis-r1/run.py']
        for required in ('sequences-underflow-r1','partial-underflow-r1',
                         "not verify['canonical_gate_passed']","prepared['statistics']['private_functional_passes']==108",
                         "cmroot=root.parent/'branch-address-soc-r1/coremark-r1'"):
            self.assertIn(required,new)
        self.assertNotIn('fetch-metadata-',new)
        self.assertNotIn('regression-audit.json',new)
        self.assertEqual(len(self.changes),4)
        partial=dict(self.changes);partial.pop('ventium/fp_shared/ven_fp_top.sv')
        with self.assertRaises(AssertionError):recipe.derive(self.original,partial)

    def test_clock_tcl_identical_and_parent_pinned(self):
        self.assertEqual(self.outputs['branch-address-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])
        self.assertIn(recipe.PARENT_DCP,self.outputs['branch-address-clock-r1/run.py'])
        self.assertIn('(-2.329)',self.outputs['branch-address-clock-r1/audit_closed.py'])


if __name__=='__main__':unittest.main()
