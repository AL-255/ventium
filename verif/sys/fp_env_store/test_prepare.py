import os
from pathlib import Path
import unittest

import prepare


class Recipe(unittest.TestCase):
    def test_scope_and_guards(self):
        root = Path(os.environ['FP_ENV_PARENT'])
        self.assertEqual(list(prepare.PARENTS), ['fp_shared/ven_fp_top.sv'])
        for name in prepare.PARENTS:
            before = (root/name).read_text()
            after = prepare.transform(before, name)
            self.assertEqual(after.replace(prepare.AFTER, prepare.BEFORE), before)
            for bad in (before+'\n', after):
                with self.assertRaises(ValueError):
                    prepare.transform(bad, name)


if __name__ == '__main__':
    unittest.main()
