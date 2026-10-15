"""Source-composition checks only: do not mistake them for native RTL runs."""
import hashlib
from pathlib import Path
import unittest

import prepare_fetch_pair_next as recipe
import build_fetch_pair_next_core as builder
import run_fetch_pair_next_replay as replay
import audit_fetch_pair_next as audit

ROOT = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')
PARENT = ROOT/'prefix-payload-core-r1/candidate'


class Composition(unittest.TestCase):
    def test_exact_independently_tested_deltas(self):
        self.assertEqual(set(recipe.PARENTS), {
            'rtl/core/core.sv', 'rtl/mem/ven_l1d.sv',
            'rtl/mem/ventium_l1_axi.sv', 'rtl/ventium_top.sv'})
        for name, digest in recipe.PARENTS.items():
            with self.subTest(name=name):
                source = (PARENT/name).read_text()
                self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), digest)
                owner = ('fetch-fragment-core-r1' if name == recipe.fetch.FILE
                         else 'pair-next-disjoint-core-r1')
                self.assertEqual(recipe.transform(source, name),
                                 (ROOT/owner/'candidate'/name).read_text())

    def test_no_partial_reapplication_or_source_drift(self):
        for name in recipe.PARENTS:
            source = (PARENT/name).read_text()
            for bad in (source+'\n', recipe.transform(source, name)):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    recipe.transform(bad, name)
        with self.assertRaises(ValueError):
            recipe.transform('', 'rtl/unknown.sv')

    def test_both_original_equivalence_observers_remain(self):
        core = recipe.transform((PARENT/recipe.fetch.FILE).read_text(), recipe.fetch.FILE)
        cache = recipe.transform((PARENT/'rtl/mem/ven_l1d.sv').read_text(),
                                 'rtl/mem/ven_l1d.sv')
        self.assertIn('assert (fx_cross === (bd_we', core)
        self.assertIn('assert (pair_lookup_active === pair_lookup_before_ack_cut)', cache)
        self.assertIn('assert (!mc_lookup_next)', cache)
        self.assertNotIn('PAIR_CURRENT_U_ONLY', cache)
        self.assertIn('((!c_req && !rd_armed) && (PAIR_NEXT_DISJOINT || !mc_lookup_next))', cache)

    def test_builder_preserves_native_engine_and_requires_both_leaf_proofs(self):
        text = builder.core_driver()
        for required in ("len(files) == 195", "== 152", "'VL_J=32'",
                         "'MemoryMax=10G','MemorySwapMax=2G'", 'pass_fds=(9,)',
                         "'-GAXI_LINE_REPLAY=0'", "'--assert'", 'return native.build(root)',
                         "('conflict-negative',1)", "'fetch-fragment-leaf-r5'",
                         "['unsat','sat','sat','sat']", "'tb_fetch_pair_next_'",
                         "['pgrep','-x','vivado']", "recipe.fetch.FILE"):
            self.assertIn(required, text)
        self.assertNotIn('promote_worker_pin', text)

    def test_replay_and_regrade_bind_new_model_without_changing_oracle(self):
        text = replay.derive()
        self.assertIn('fetch-pair-next-core-r1', text)
        self.assertIn('8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1', text)
        self.assertIn('fetch-fragment-owned-func-r2', text)
        checked = audit.derive()
        self.assertIn('import prepare_fetch_pair_next as recipe', checked)
        self.assertIn('fetch-pair-next-coldalias-r1', checked)
        self.assertIn('fetch-pair-next-regression-audit.json', checked)
        self.assertIn('assert (records,comparisons,first_pairs)==(15840,144,72)', checked)
        module = {'__name__':'composition_audit_test', '__file__':str(audit.__file__)}
        exec(compile(checked, '<derived-audit>', 'exec'), module)
        _, grader = module['derive']()
        self.assertIn('fetch-pair-next-regression-audit.json', grader)
        self.assertIn('sorted(recipe.PARENTS)', grader)


if __name__ == '__main__':
    unittest.main()
