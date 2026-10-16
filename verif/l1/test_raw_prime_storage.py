import hashlib
from pathlib import Path
import unittest

import prepare_raw_prime_storage as recipe
import build_raw_prime_storage_core as build
import run_raw_prime_storage as run

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve()
SOURCE = ROOT/'sfetch-boundary-core-r1/candidate/rtl/core'


class Recipe(unittest.TestCase):
    def test_exact_reversible_storage_only_change(self):
        old = (SOURCE/'core_mem_chain.svh').read_text()
        new = recipe.transform(old)
        self.assertEqual(new.replace(recipe.replacement(old), recipe.storage(old)), old)
        for name in recipe.STATE:
            self.assertIn(f"assign {name} = '0;", new)
            self.assertIn('raw_storage_ref_'+name, new)
        # The old non-RAW block remains intact, including every cancel/flush.
        self.assertIn('`else\n'+recipe.storage(old)+'`endif', new)
        self.assertEqual(hashlib.sha256(old.encode()).hexdigest(), recipe.PARENT)

    def test_parent_and_guard_drift_rejected(self):
        old = (SOURCE/'core_mem_chain.svh').read_text()
        for bad in (old+'\n', recipe.transform(old), old.replace('mc_prime_base &&', '1\'b1 &&')):
            with self.assertRaises(ValueError):
                recipe.transform(bad)

    def test_leaf_covers_legacy_and_broken_contracts(self):
        self.assertEqual(len(run.JOBS), 6)
        for raw, mode in run.JOBS:
            text = run.fixture(SOURCE, raw, mode)
            self.assertIn('RAW-STORAGE-OK checks=', text)
            self.assertIn('RAW-STORAGE-LEGACY-VACUOUS', text)
            self.assertIn('n<16385', text)
            self.assertIn('typedef struct packed', text)

    def test_compiler_guards_and_source_closure_preserved(self):
        text = build.adapted_main()
        for token in ('len(files) == 195', 'len(set(definitions)) == 153',
                      'MemoryMax=10G', 'MemorySwapMax=2G', 'pass_fds=(9,)',
                      "'--assert' in flags", "'VL_J=32'", 'native.stable(pins)',
                      'native.build(root)'):
            self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
