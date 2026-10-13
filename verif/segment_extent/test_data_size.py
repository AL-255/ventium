import os
from pathlib import Path
import re
import unittest

import prepare_data_size as recipe


class DataSizeRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before = Path(os.environ['DATA_SIZE_PARENT']).read_text()
        cls.after = recipe.transform(cls.before)

    def test_exact_delta(self):
        restored = self.after
        for before, after in reversed(recipe.edits()[1:]):
            self.assertEqual(restored.count(after), 1)
            restored = restored.replace(after, before)
        fetch = ('        cur_lin_nat = sfetch_boundary ? sfetch_demand_addr\n'
                 '                                     : flin + {27\'d0,fetch_word,2\'b00};\n')
        self.assertEqual(restored.count(fetch), 1)
        restored = restored.replace(fetch, fetch + recipe.FETCH_SIZE)
        self.assertEqual(restored, self.before)

    def test_one_width_producer(self):
        begin = self.before.index('    cur_lin_nat  = 32\'d0;')
        end = self.before.index(recipe.ANCHOR, begin)
        block = re.sub(r'//[^\n]*', '', self.before[begin:end])
        self.assertEqual(len(re.findall(r'\bcur_size\b', block)),
                         len(re.findall(r'\bcur_size\s*=', block)))
        self.assertEqual(self.after.count(recipe.TAP), 1)
        self.assertEqual(self.after.count('seg_extent_above(seg_chk_off,'), 2)
        self.assertIn('S_FETCH, S_PF: cur_is_d = 1\'b0;',
                      recipe.classification(self.after))

    def test_fetch_and_descriptor_qualifiers_unchanged(self):
        start = '    cs_fetch_fault = sys_mode'
        end = '    seg_access_fault = cur_is_d'
        self.assertEqual(self.before.split(start)[1].split(end)[0],
                         self.after.split(start)[1].split(end)[0])
        self.assertEqual(recipe.classification(self.before), recipe.classification(self.after))
        self.assertEqual(recipe.extent_function(self.before), recipe.extent_function(self.after))

    def test_drift_and_reapplication_rejected(self):
        for text in (self.before+'\n', self.after):
            with self.assertRaises(ValueError):
                recipe.transform(text)


if __name__ == '__main__':
    unittest.main()
