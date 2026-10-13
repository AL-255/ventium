import os
from pathlib import Path
import unittest

import prepare_write_class as recipe


class WriteClass(unittest.TestCase):
    def test_exact_delta_and_rejection(self):
        before=Path(os.environ['ENV_WRITE_DECODER']).read_text()
        after=recipe.transform(before)
        self.assertEqual(after.count("d_f_mem_write=1'b1"),before.count("d_f_mem_write=1'b1")+2)
        restored=after
        for old,new in reversed(recipe.EDITS):
            self.assertEqual(restored.count(new),1)
            restored=restored.replace(new,old)
        self.assertEqual(before,restored)
        for wrong in (before+'\n',after):
            with self.assertRaises(ValueError): recipe.transform(wrong)


if __name__=='__main__': unittest.main()
