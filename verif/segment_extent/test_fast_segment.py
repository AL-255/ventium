import os
from pathlib import Path
import unittest

import prepare_fast_segment as recipe


class FastSegmentRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old = Path(os.environ['FAST_SEGMENT_PARENT']).read_text()
        cls.new = recipe.transform(cls.old)

    def test_only_admission_changes(self):
        self.assertEqual(self.new.replace(recipe.NEW, recipe.block(self.old)), self.old)
        self.assertEqual(recipe.leaf(self.old).split(recipe.END)[1],
                         recipe.leaf(self.new).split(recipe.END)[1])

    def test_bounded_descriptor_not_late_selected(self):
        branch = recipe.NEW.split('`ifdef VEN_SYS_FASTLOAD_BOUNDED')[1]
        self.assertNotIn('[pipe_mem_seg]', branch)
        self.assertIn('(pipe_mem_seg == 3\'(SG_DS))', branch)
        self.assertIn('!seg_attr[fs][2]', recipe.NEW)
        self.assertEqual(self.old.count('localparam int SG_CS = 0, SG_SS = 1, SG_DS = 2,'), 1)

    def test_drift_and_reapplication_fail(self):
        for source in (self.old+'\n', self.new):
            with self.assertRaises(ValueError):
                recipe.transform(source)


if __name__ == '__main__':
    unittest.main()
