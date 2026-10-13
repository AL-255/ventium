"""Host-only scope and guard tests, not a native cache result."""
import ast
import os
from pathlib import Path
import unittest

import prepare_window_current_reuse as recipe
import run_window_current_cache as cache
from test_window_current_reuse import scope


class WindowCurrent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['WINDOW_CURRENT_SOURCE']).read_text()

    def test_reversible_scope(self):
        changed = recipe.transform(self.source)
        scope(self.source, changed)
        for name in ('window_reuse', 'shadow_reuse'):
            self.assertIn(recipe.witness(recipe.equation(self.source, name), name), changed)

    def test_mutation_retains_witnesses_and_shadow(self):
        changed = recipe.transform(self.source)
        mutant = cache.mutate(changed, self.source, recipe)
        self.assertNotEqual(changed, mutant)
        for name in ('window_reuse', 'shadow_reuse'):
            self.assertIn(recipe.witness(recipe.equation(self.source, name), name), mutant)
        shadow = recipe.replacement(recipe.equation(self.source, 'shadow_reuse'))
        self.assertIn(shadow, mutant)

    def test_same_native_guards_and_traffic(self):
        text = cache.derive()
        ast.parse(text)
        for marker in ('admit_proof(proof)', 'len(defines)==152', 'run_fresh_pair_capture()',
                       'c_pair_intent_ready=1', 'c_rdata_hi_uncontended=1',
                       'miter.miter_fixture(tb,False,True)', 'for mutant in (False,True)',
                       'dut.shadow_line_q !== control.shadow_line_q',
                       'dut.window_reuse !== control.window_reuse',
                       'dut.shadow_reuse !== control.shadow_reuse',
                       'pass_fds=(9,)', "['pgrep','-x','vivado']",
                       'whole_core=False', 'hardware_acceptance=False'):
            self.assertIn(marker, text)
        previous = cache.previous.derive()
        start, end = '            command=[', "            row=dict(mutant="
        self.assertEqual(text[text.index(start):text.index(end)],
                         previous[previous.index(start):previous.index(end)])
        for marker in ('L1D-MEM-CHAIN-OK accepted=150', 'WINDOW-WRITE-UPDATE-OK',
                       'STORE-WARM-OK', 'RESPONSE-PAYLOAD-OK', 'HIGH-WINDOW-PAYLOAD-OK',
                       'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):
            self.assertIn(marker, text)


if __name__ == '__main__':
    unittest.main()
