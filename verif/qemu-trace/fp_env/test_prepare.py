import os
from pathlib import Path
import unittest

import prepare


class Recipe(unittest.TestCase):
    def test_guard_and_scope(self):
        text = Path(os.environ['QEMU_FP_HELPER']).read_text()
        result = prepare.transform(text)
        first = text.index('static void do_fstenv(')
        last = text.index('void helper_fldenv(')
        self.assertEqual(text[:first], result[:first])
        self.assertEqual(text[last:], result[result.index('void helper_fldenv('):])
        for bad in (text+'\n', result):
            with self.assertRaises(ValueError):
                prepare.transform(bad)
        self.assertIn(prepare.LOAD_AFTER, result)
        self.assertIn(prepare.STORE_AFTER, result)
        self.assertIn(prepare.STORE16_AFTER, result)
        self.assertEqual(result.count('bool real_format = !(env->hflags & HF_PE_MASK) || (env->eflags & VM_MASK);'), 2)
        self.assertNotIn('env->hflags & HF_VM_MASK', result)


if __name__ == '__main__':
    unittest.main()
