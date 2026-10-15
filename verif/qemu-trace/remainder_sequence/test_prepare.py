import os
from pathlib import Path
import unittest

import prepare


class Recipe(unittest.TestCase):
    def test_local_change_and_drift(self):
        before = Path(os.environ['QEMU_FPREM_PARENT']).read_text()
        after = prepare.transform(before)
        self.assertEqual(before.split(prepare.START)[0], after.split(prepare.START)[0])
        self.assertEqual(before.split(prepare.END)[1], after.split(prepare.END)[1])
        helper = after.split(prepare.START)[1].split(prepare.END)[0]
        self.assertEqual(helper.count('set_floatx80_rounding_precision('), 2)
        self.assertLess(helper.index('set_floatx80_rounding_precision(floatx80_precision_x'),
                        helper.index('floatx80_scalbn('))
        self.assertLess(helper.index('set_floatx80_rounding_precision(precision'),
                        helper.index('merge_exception_flags('))
        self.assertNotIn('float_flag_inexact', helper)
        with self.assertRaises(ValueError):
            prepare.transform(after)
        with self.assertRaises(ValueError):
            prepare.transform(before+'\n')


if __name__ == '__main__':
    unittest.main()
