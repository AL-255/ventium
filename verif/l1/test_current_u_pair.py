"""Host checks for the private current-U interface specialization."""
import os
from pathlib import Path
import unittest

import prepare_current_u_pair as recipe

SOURCE = Path(os.environ.get('CURRENT_U_PAIR_PARENT',
    '/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/prefix-payload-core-r1/candidate'))


class Recipe(unittest.TestCase):
    def test_exact_parent_and_reapplication(self):
        for name in recipe.PARENTS:
            with self.subTest(name=name):
                source = (SOURCE/name).read_text()
                changed = recipe.transform(source, name)
                self.assertNotEqual(source, changed)
                for bad in (source+'\n', changed):
                    with self.assertRaises(ValueError): recipe.transform(bad, name)

    def test_generic_predicate_retained(self):
        old = (SOURCE/'rtl/mem/ven_l1d.sv').read_text()
        new = recipe.transform(old, 'rtl/mem/ven_l1d.sv')
        self.assertIn("parameter bit PAIR_CURRENT_U_ONLY = 1'b0", new)
        self.assertIn('PAIR_CURRENT_U_ONLY ? pair_legacy_capture :', new)
        self.assertIn('(pair_legacy_bank_owned && !mc_lookup_next)', new)
        self.assertEqual(new.count('assign pair_bank_ready'), 1)

    def test_top_selection_excludes_prime_and_store_clients(self):
        old = (SOURCE/'rtl/ventium_top.sv').read_text()
        new = recipe.transform(old, 'rtl/ventium_top.sv')
        self.assertIn('`ifdef VEN_P54_DUAL_LOAD_PAIR\n`ifndef VEN_P54_DUAL_LOAD_PRIME\n'
                      '`ifndef VEN_P54_STORE_LOAD_PAIR', new)
        self.assertEqual(new.count('.PAIR_CURRENT_U_ONLY'), 1)


if __name__ == '__main__': unittest.main()
