"""Source-contract tests only; not whole-core correctness or FPGA acceptance."""
import argparse
from pathlib import Path
import unittest

import prepare_lmsw as recipe


class SourceContract(unittest.TestCase):
    sources = {}

    def test_exact_scope_drift_and_reapplication(self):
        self.assertEqual(len(self.sources), 5)
        for name, original in self.sources.items():
            changed = recipe.transform(original, name)
            self.assertNotEqual(original, changed)
            self.assertEqual(original.count('always_'), changed.count('always_'))
            self.assertEqual(original.count('`ifdef'), changed.count('`ifdef'))
            for bad in (original+'\n', changed):
                with self.assertRaises(ValueError):
                    recipe.transform(bad, name)

    def test_low_bits_and_sticky_pe(self):
        # Independent architectural expressions, including varied high bits.
        for high in (0, 0x10, 0x60000010, 0x80000030, 0xfffffff0):
            for old_low in range(16):
                for src in range(16):
                    old = high | old_low
                    actual = (old & 0xfffffff1) | src
                    expected = (old & ~15) | src | (old & 1)
                    self.assertEqual(actual, expected)
                    self.assertEqual(actual & ~15, old & ~15)
                    self.assertFalse((old & 1) and not (actual & 1))

    def test_existing_commit_and_precise_load(self):
        new = {name: recipe.transform(text, name) for name, text in self.sources.items()}
        self.assertIn(recipe.LMSW_DECODE, new['decode_stages.sv'])
        self.assertIn(recipe.CR0_VALUE, new['core.sv'])
        self.assertIn('SYS_MOVCR_TO: state<=d_mem_read ? S_LOAD : S_EXEC;', new['core_fetch_decode.svh'])
        self.assertIn('q_lmsw<=d_lmsw;', new['core_refdecode_latch.svh'])
        self.assertIn("3'd0: creg0<=cr0_exec_value;", new['core_exec.svh'])
        self.assertEqual(new['core_exec.svh'].count('creg0<='), self.sources['core_exec.svh'].count('creg0<='))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    SourceContract.sources = {name: (args.source/name).read_text() for name in recipe.PARENTS}
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SourceContract))
    raise SystemExit(not result.wasSuccessful())
