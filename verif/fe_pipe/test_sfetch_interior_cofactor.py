from pathlib import Path
import unittest

import prepare_sfetch_interior_cofactor as recipe
import run_sfetch_interior_cofactor as run

SOURCE=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/next-ready-soc-r1/source/rtl/core/core.sv')


class InteriorCofactor(unittest.TestCase):
    def test_exact_selector_only_and_reapplication_rejected(self):
        old=SOURCE.read_text();new=recipe.transform(old)
        self.assertEqual(recipe.want_block(old),recipe.want_block(new))
        start=old.index(recipe.OLD_SELECT);end=start+len(recipe.OLD_SELECT)
        self.assertTrue(new.startswith(old[:start]))
        self.assertTrue(new.endswith(old[end:]))
        self.assertIn('sfetch_demand_size === sfetch_demand_size_before_interior_cut',new)
        for bad in (new,old+'\n'):
            with self.assertRaises(ValueError):recipe.transform(bad)

    def test_output_helper_has_no_decoder_or_request_dependency(self):
        for name in ('d_fetch_need','sfetch_valid_q','sfetch_want_size','sfetch_want_req','mem_ack'):
            self.assertNotIn(name,recipe.HELPER)
        self.assertIn("13'h1000",recipe.HELPER)
        self.assertIn('sfetch_interior16 ? sfetch_interior_size :',recipe.NEW_SELECT)

    def test_extracted_equations_and_mutants(self):
        old=SOURCE.read_text()
        self.assertIn(recipe.want_block(old),run.fixture(old,'positive'))
        for mode in run.MODES[1:]:
            self.assertNotEqual(run.fixture(old,'positive'),run.fixture(old,mode))
        self.assertEqual(run.symbolic()[1],['unsat','sat','sat','sat','sat'])

    def test_builder_retains_native_guards_and_faster_parent(self):
        import build_sfetch_interior_core as builder
        text=builder.adapted_main()
        for token in ('pass_fds=(9,)', "'MemoryMax=10G'", "'MemorySwapMax=2G'",
                      "'VL_J=32'", 'native.build(root)', "(leaf/'core.sv')"):
            self.assertIn(token,text)
        self.assertEqual(builder.MODEL,'e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a')


if __name__=='__main__':unittest.main()
