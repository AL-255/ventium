"""Source contract tests; native helper and whole-core checks are separate."""
import os
from pathlib import Path
import unittest

from prepare_carry_rotate_tree import EDITS, HELPER, transform


class CarryRotateRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['CARRY_ROTATE_PARENT']).read_text()

    def test_exact_reversible_change(self):
        changed = transform(self.source)
        self.assertNotIn('for(i=0;i<32;i++)', changed)
        self.assertEqual(changed.count(HELPER), 1)
        for old, new in reversed(EDITS):
            changed = changed.replace(new, old, 1)
        self.assertEqual(changed, self.source)

    def test_no_other_helpers_change(self):
        changed = transform(self.source)
        for name in ('alu_result', 'flags_next', 'fast_shift_flags',
                     'shld_result', 'shld_cf', 'wmask'):
            def body(source):
                start = source.index(' '+name+'(')
                return source[start:source.index('  endfunction', start)]
            self.assertEqual(body(changed), body(self.source), name)

    def test_reject_drift_and_reapplication(self):
        for source in (self.source+'\n', transform(self.source)):
            with self.assertRaises(ValueError):
                transform(source)


if __name__ == '__main__':
    unittest.main()
