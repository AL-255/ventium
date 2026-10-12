"""Rebase/source checks; no cache, core or timing acceptance."""
import os
import re
from pathlib import Path
import unittest

import prepare_pair_overlap_current as recipe
import prepare_pair_now_ack_cut as same_line
import prepare_pair_overlap_ack_cut as overlap
import test_pair_overlap_ack_cut as proof


class Tests(unittest.TestCase):
    def setUp(self):
        self.source = (Path(os.environ['IC_FILL_PARENT'])/'rtl/mem/ven_l1d.sv').read_text()

    def test_exact_inverse_and_orthogonal_changes(self):
        old = recipe.restore_parent(self.source)
        self.assertEqual(same_line.transform(old), self.source)
        new = recipe.transform(self.source)
        before = overlap.extract_lookup(self.source)
        after = overlap.extract_lookup(new)
        self.assertEqual(new.replace(overlap.OWNED+after+overlap.witness(before), before), self.source)
        self.assertEqual(same_line.extract(new), same_line.extract(self.source))

    def test_proof_sources_are_still_exact(self):
        old = recipe.restore_parent(self.source)
        # The qualified proof extracts exactly these three source regions.
        def extracted(source):
            start = source.rindex("    c_ack   = 1'b0;\n")
            end = source.index('  end\n\n`ifndef SYNTHESIS\n`ifndef VEN_L1D_COMB_ACK', start)
            return (source[start:end],
                source[source.index(overlap.OVERLAP_START):source.index(overlap.OVERLAP_END)],
                overlap.extract_lookup(source))
        self.assertEqual(extracted(old), extracted(self.source))
        for mutant in (None, 'orphan-v', 'unowned-read', 'snoop'):
            generated = proof.fixture(old, mutant)
            self.assertNotIn('pair_now', re.sub(r'//[^\n]*', '', generated))
            self.assertIn('PAIR-OVERLAP-MISMATCH', generated)

    def test_source_drift_and_reapplication_fail(self):
        for changed in (self.source+'\n', recipe.transform(self.source)):
            with self.assertRaises(ValueError):
                recipe.transform(changed)


if __name__ == '__main__':
    unittest.main()
