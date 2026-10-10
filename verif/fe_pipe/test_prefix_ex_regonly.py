"""Fail-closed recipe checks; native RTL equivalence is a separate gate."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('recipe', Path(__file__).with_name('prepare-prefix-ex-regonly.py'))
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


class RecipeTest(unittest.TestCase):
    def source(self):
        return ('p54_prefix_ex_shape_ok = p54_prefix_ex_shape_ok &&\n' +
                recipe.OLD + '\n`ifdef VEN_P54_PREFIX_EX_SYSTEM\n' +
                '    !d_mem_read && !d_mem_write && !def16 && !smm_active &&\n' +
                '    !(intr && eflags[9]) && p54_prefix_ex_shape_ok && other;\n`endif\n')

    def test_only_reviewed_guard_changes(self):
        before = self.source()
        self.assertEqual(recipe.transform(before).replace(recipe.NEW, recipe.OLD), before)

    def test_reject_double_application(self):
        with self.assertRaises(ValueError):
            recipe.transform(recipe.transform(self.source()))

    def test_reject_missing_dependencies(self):
        for missing in (recipe.OLD, '`ifdef VEN_P54_PREFIX_EX_SYSTEM',
                        '!d_mem_read && !d_mem_write', '!(intr && eflags[9])'):
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                recipe.transform(self.source().replace(missing, ''))

    def test_reject_duplicate_guard(self):
        with self.assertRaises(ValueError):
            recipe.transform(self.source() + recipe.OLD)

    def test_reject_new_consumers(self):
        for extra in ('gpr_we', 'p54_prefix_ex_shape_ok &&'):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                recipe.transform(self.source() + extra)


if __name__ == '__main__':
    unittest.main()
