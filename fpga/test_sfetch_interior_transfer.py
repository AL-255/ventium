import ast
from pathlib import Path
import unittest

import build_sfetch_interior_soc as builder
import run_sfetch_interior_coremark as cm
import audit_sfetch_interior_coremark as audit


class Transfer(unittest.TestCase):
    def test_only_exact_cofactor_moves(self):
        before=(builder.ROOT/'sfetch-boundary-soc-r1/source'/builder.recipe.FILE).read_bytes()
        after=(builder.ROOT/'sfetch-interior-core-r1/candidate'/builder.recipe.FILE).read_bytes()
        self.assertTrue(builder.check_delta(builder.recipe.FILE,before,after))
        self.assertFalse(builder.check_delta('unchanged',b'a',b'a'))
        with self.assertRaises(AssertionError):builder.check_delta('unchanged',b'a',b'b')
        with self.assertRaises(AssertionError):builder.check_delta(builder.recipe.FILE,before,after+b'\n')
        ast.parse(builder.prepare_source())

    def test_parallel_seeds_keep_native_crc_and_duration_guards(self):
        text=cm.derive();ast.parse(text)
        for marker in ('max_workers=2','child.wait(timeout=600)', 'reference_crcs=crcs',
                       'iterations=10,require_valid_duration=False','result.update(cost(seed',
                       'actual_wait=True','proc_gone=not proc.exists()',"str(cpu)]+argv"):
            self.assertIn(marker,text)
        self.assertEqual(cm.cost('performance',4771298)['added_clocks'],0)
        with self.assertRaises(AssertionError):cm.cost('performance',4771299)

    def test_audit_keeps_original_comparisons_and_both_affinities(self):
        text=audit.derive();ast.parse(text)
        for marker in ("native['affinity'] == [12 if seed=='performance' else 13]",
                       "ref['crcs'] == result['crcs'] == item['crcs']", "native['argv'] == argv",
                       "old['ticks']==runner.TICKS[seed]", 'duration_valid=False,standard_suite=False'):
            self.assertIn(marker,text)


if __name__=='__main__':unittest.main()
