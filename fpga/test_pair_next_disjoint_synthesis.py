"""Controller derivation must not weaken the proven native resource lifecycle."""
import json
from pathlib import Path
import unittest

import prepare_pair_next_disjoint_synthesis as recipe


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(recipe.ROOT/n).read_text() for n in recipe.templates.TEMPLATES}
        manifest=json.loads((recipe.ROOT/'pair-next-disjoint-fpga-r1/input-manifest.json').read_text())
        cls.changes={r['frozen']:r['sha256'] for r in manifest['files']
                     if r['frozen'] in manifest['changed_parent_payloads']}
        cls.outputs=recipe.derive(cls.original,cls.changes)

    def test_native_lifecycle_is_byte_identical(self):
        for phase in ('synthesis','clock'):
            old=self.original[f'prefix-payload-{phase}-r1/run.py']
            new=self.outputs[f'pair-next-disjoint-{phase}-r2/run.py']
            boundary='owner = None\n'
            self.assertEqual(old[old.index(boundary):],new[new.index(boundary):])

    def test_synthesis_admission_not_relaxed(self):
        old=self.original['prefix-payload-synthesis-r1/run.py']
        new=self.outputs['pair-next-disjoint-synthesis-r2/run.py']
        a,b='host = available()\n',"(root/'once').mkdir()"
        self.assertEqual(old[old.index(a):old.index(b)],new[new.index(a):new.index(b)])
        for required in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                         'memory+swap > 13*gib','if free < 4*gib:',"VEN_FPGA_CORE_MHZ='40'"):
            self.assertIn(required,new)

    def test_new_proofs_and_honest_acceptance(self):
        new=self.outputs['pair-next-disjoint-synthesis-r2/run.py']
        for required in ('pair-next-disjoint-coldalias','first_v_pairs=72',
                         "('conflict-negative',1)","cmroot=root.parent/'pair-next-disjoint-soc-r1/coremark-r1'",
                         'not verify[\'canonical_gate_passed\']'):
            # coldalias folder is constructed from a suffix, not a literal.
            if required=='pair-next-disjoint-coldalias':required="('coldalias',144)"
            self.assertIn(required,new)
        self.assertNotIn("load_proof('pair-next-disjoint-env-fault",new)

    def test_identical_clock_audit_tcl(self):
        self.assertEqual(self.outputs['pair-next-disjoint-clock-r2/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])
        self.assertIn('(-2.329)',self.outputs['pair-next-disjoint-clock-r2/audit_closed.py'])


if __name__=='__main__':unittest.main()
