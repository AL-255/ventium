import os
from pathlib import Path
import unittest

import prepare as recipe


class ExtentRecipe(unittest.TestCase):
    def test_exact_delta_and_reapplication(self):
        source = Path(os.environ['EXTENT_PARENT']).read_text()
        after = recipe.transform(source)
        self.assertEqual(after.count(recipe.FUNCTION), 1)
        self.assertEqual(after.count('seg_extent_above(seg_chk_off,'), 2)
        self.assertNotIn('logic [32:0] last_byte;', after)
        self.assertIn('logic        seg_access_fault;', after)
        for drift in (source+'\n', after):
            with self.assertRaises(ValueError):
                recipe.transform(drift)


if __name__ == '__main__':
    unittest.main()
