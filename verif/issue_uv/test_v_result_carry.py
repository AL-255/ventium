"""Exact-source/scope tests; actual RTL execution is a separate leaf gate."""
from pathlib import Path
import unittest

import prepare_v_result_carry as recipe
import run_v_result_carry_leaf as leaf

PARENT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/pipe-wait-core-r1/candidate')


class VResultCarry(unittest.TestCase):
    def test_only_result_carry_changes_in_hardware(self):
        for name in recipe.HASHES:
            old=(PARENT/name).read_text();new=recipe.transform(old,name)
            if name.endswith('/v_pipe.sv'):
                self.assertEqual(new.replace(recipe.NEW,recipe.OLD),old)
                self.assertIn('flags_next(v_d.alu_op, v_a_w, v_b_w, v_alu, eflags, fp_operand_width(v_d))',new)
            else:
                self.assertEqual(new.replace(recipe.WITNESS,''),old)
        self.assertIn('pipe_int_commit && pipe_pair_eff',recipe.WITNESS)
        self.assertIn('pipe_v_eff.pairs_second',recipe.WITNESS)
        self.assertIn('ALU_ADC',recipe.WITNESS);self.assertIn('ALU_SBB',recipe.WITNESS)

    def test_drift_reapplication_and_unlisted_source_rejected(self):
        for name in recipe.HASHES:
            old=(PARENT/name).read_text()
            for bad in (old+'\n',recipe.transform(old,name)):
                with self.assertRaises(ValueError):recipe.transform(bad,name)
        with self.assertRaises(ValueError):recipe.transform('','rtl/core/decode.sv')

    def test_complete_matrix_counts(self):
        modrm_sib=sum(256 if mr%8==4 and mr//64!=3 else 1 for mr in range(256))
        self.assertEqual(4*256*modrm_sib+5,leaf.COUNTS['decode'])
        operands=256**2+2*79**2
        self.assertEqual(30*2*2*operands,leaf.COUNTS['alu'])
        self.assertEqual(2*2*operands,leaf.COUNTS['incdec_cf_one'])

    def test_native_fixture_keeps_real_decoder_and_issuer(self):
        text=Path(leaf.__file__).with_name('tb_v_result_carry.sv').read_text()
        for required in ('decode decoder(', 'decode u_decoder(', 'issue_uv issuer(',
                         'v_pipe_parent reference(', 'v_pipe candidate(', 'mutant==1', 'mutant==2',
                         'V-CARRY-DATAPATH', 'V-CARRY-ELIGIBILITY'):
            self.assertIn(required,text)
        self.assertNotIn('force ',text)
        self.assertIn('accepted_v<1000',text)
        self.assertIn('!u_decoded.is_nop',text)

    def test_disabled_regmem_path_is_not_enabled_for_coverage(self):
        import json
        definitions=json.loads((PARENT.parent/'build-started.json').read_text())['definitions']
        self.assertNotIn('VEN_P54_REGMEM_PRIME',definitions)
        self.assertEqual(leaf.class_mask(definitions),[True,True,False,True,True])
        self.assertEqual(leaf.class_mask([]),[True,False,False,False,False])


if __name__=='__main__':unittest.main()
