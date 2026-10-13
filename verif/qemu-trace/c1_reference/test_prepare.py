import os
from pathlib import Path
import unittest

import prepare


class Recipe(unittest.TestCase):
    def test_composition(self):
        root = Path(os.environ['QEMU_SOURCE'])
        names = set(prepare.rounding.PARENTS)|set(prepare.remainder.PARENTS)|{prepare.HELPER}
        original = {n:(root/n).read_text() for n in names}
        result = prepare.transform(original)
        self.assertEqual(set(result), names)
        for name in names:
            self.assertNotEqual(result[name], original[name])
        with self.assertRaises(ValueError):
            prepare.transform(result)
        bad = dict(original)
        bad[prepare.HELPER] += '\n'
        with self.assertRaises(ValueError):
            prepare.transform(bad)
        helper = result[prepare.HELPER]
        self.assertEqual(helper.count('vtm_fpu_round_c1(env);'), 12)
        self.assertIn('floatx80_lt(floatx80_abs(before), floatx80_abs(ST0),', helper)
        self.assertIn(prepare.environment.LOAD_AFTER, helper)
        # Neither internal pushes/pops nor architectural observation gets a
        # blanket clear that would erase instruction-specific condition codes.
        for signature in ('static inline void fpush(', 'static inline void fpop(',
                          'void helper_fpop(', 'void helper_fxam_ST0(',
                          'void helper_fprem1(', 'void helper_fwait('):
            a = original[prepare.HELPER]
            b = helper
            start_a, start_b = a.index(signature), b.index(signature)
            end_a, end_b = a.index('\n}\n',start_a)+3, b.index('\n}\n',start_b)+3
            self.assertEqual(a[start_a:end_a], b[start_b:end_b])

    def test_merge_rejects_overlap(self):
        with self.assertRaises(ValueError):
            prepare.merge('a\nb\nc\n', 'a\nB\nc\n', 'a\nx\nc\n')
        self.assertEqual(prepare.merge('a\nb\nc\n','a\nB\nc\n','a\nb\nC\n'), 'a\nB\nC\n')


if __name__=='__main__':
    unittest.main()
