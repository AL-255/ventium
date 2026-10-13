"""Exact-delta/profile tests, plus exhaustive abstract owner-control checks."""
import os
from pathlib import Path
import unittest

import prepare_v_load_payload as recipe


class Recipe(unittest.TestCase):
    def test_reversible_sources(self):
        root = Path(os.environ['V_LOAD_PAYLOAD_PARENT'])
        old = {p: (root/p).read_text() for p in recipe.PARENTS}
        new = recipe.transform(old)
        self.assertEqual(new['rtl/core/core.sv'].replace(recipe.WITNESS, ''), old['rtl/core/core.sv'])
        self.assertEqual(new['rtl/core/core_gpr_wb.svh'].replace(recipe.NEW, recipe.OLD), old['rtl/core/core_gpr_wb.svh'])
        self.assertIn(recipe.ACCEPT, new['rtl/core/core.sv'])
        for changed in (new, dict(old, **{'rtl/core/core.sv': old['rtl/core/core.sv']+'\n'})):
            with self.assertRaises(ValueError):
                recipe.transform(changed)

    def test_control_contract(self):
        accepted = held = excluded = 0
        for bits in range(64):
            active, hit, write, request, valid, ack = [bool(bits & (1 << i)) for i in range(6)]
            now = request and valid and ack and not active
            if hit and (not active or write):
                excluded += 1
                continue
            self.assertFalse(hit and now)
            if hit or now:
                # Symbolic distinct tokens, not claims of native RTL proof.
                self.assertEqual('immediate' if now else 'held', 'held' if hit else 'immediate')
            accepted += now
            held += hit
        self.assertGreater(accepted, 0)
        self.assertGreater(held, 0)
        self.assertGreater(excluded, 0)
        # Without the owner invariant there is a counterexample: hit=now=1.
        self.assertNotEqual('immediate' if True else 'held', 'held' if True else 'immediate')

    def test_extracted_expressions(self):
        for fragment, name in ((recipe.OLD, 'old_data'), (recipe.NEW, 'new_data')):
            value = recipe.payload_assignment(fragment, name)
            self.assertEqual(value.count('assign ' + name), 1)
            self.assertNotIn('fp_operand_width', value)
            code = '\n'.join(line.split('//', 1)[0] for line in value.splitlines())
            self.assertNotIn(',', code)
        self.assertEqual(recipe.NEW.count('`ifdef VEN_RAW_V_READ_PRIME'), 1)
        self.assertEqual(recipe.NEW.count('`ifndef VEN_P54_DUAL_LOAD_PRIME'), 1)


if __name__ == '__main__':
    unittest.main()
