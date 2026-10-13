import os
from pathlib import Path
import unittest
import prepare


class Recipe(unittest.TestCase):
    def test_only_frndint_changes(self):
        text = Path(os.environ['QEMU_FRNDINT_PARENT']).read_text()
        changed = prepare.transform(text)
        self.assertEqual(changed.replace(prepare.AFTER, prepare.BEFORE), text)
        with self.assertRaises(ValueError):
            prepare.transform(changed)
        with self.assertRaises(ValueError):
            prepare.transform(text+'\n')
        self.assertEqual(changed.count('set_floatx80_rounding_precision(precision, &env->fp_status);'), 1)


if __name__ == '__main__':
    unittest.main()
