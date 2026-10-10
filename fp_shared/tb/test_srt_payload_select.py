"""Source-contract checks; native selector equivalence is a separate gate."""
from pathlib import Path
import unittest

import prepare_srt_payload_select as recipe


class PayloadRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(__file__).resolve().parents[1].joinpath('ven_fp_top.sv').read_text()

    def test_default_off_identity(self):
        new = recipe.transform(self.source)
        first = new.index('`ifdef '+recipe.FLAG+'\n')
        mid = new.index('\n`else\n', first)
        last = new.index('\n`endif', mid)
        disabled = new[:first]+new[mid+len('\n`else\n'):last]+new[last+len('\n`endif'):]
        self.assertEqual(disabled.split(), self.source.split())

    def test_no_admission_dependency_in_payload_block(self):
        for token in ('accept', 'issue_stack_fault', 'div_special_hit', 'sqrt_special_hit'):
            # Ignore explanatory comments, but not executable input references.
            executable = '\n'.join(line.split('//', 1)[0] for line in recipe.PAYLOAD.splitlines())
            self.assertNotIn(token, executable)
        self.assertNotIn('srt_start =', recipe.PAYLOAD)
        self.assertNotIn('srt_rc', recipe.active_block(self.source))
        self.assertNotIn('srt_pc', recipe.active_block(self.source))

    def test_duplicate_or_missing_boundaries(self):
        for marker in (recipe.BEGIN, recipe.END):
            with self.subTest(marker=marker):
                with self.assertRaises(ValueError):
                    recipe.transform(self.source.replace(marker, ''))
                with self.assertRaises(ValueError):
                    recipe.transform(self.source+marker)

    def test_refuse_live_rounding_or_changed_assignment_shape(self):
        for addition in ('    srt_rc = 0;\n', '    srt_a = 0;\n'):
            with self.subTest(addition=addition), self.assertRaises(ValueError):
                recipe.transform(self.source.replace(recipe.BEGIN, recipe.BEGIN+addition))

    def test_refuse_missing_consumer_or_double_application(self):
        with self.assertRaises(ValueError):
            recipe.transform(self.source.replace('      .a(srt_a),', '      .a(other),'))
        with self.assertRaises(ValueError):
            recipe.transform(recipe.transform(self.source))


if __name__ == '__main__':
    unittest.main()
