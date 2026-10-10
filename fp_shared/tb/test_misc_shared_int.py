"""Host recipe tests only; RTL miter is run separately."""
from pathlib import Path
import unittest

from prepare_misc_shared_int import transform


class Recipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(__file__).resolve().parents[1].joinpath('ven_fp_misc.sv').read_text()

    def test_one_call_no_new_stage_register_or_port(self):
        result = transform(self.parent)
        self.assertEqual(result.count('fx_to_int_ex('), 1)
        for prefix in ('  typedef enum', '  logic ', '    input ', '    output ', '          state '):
            self.assertEqual(sum(l.startswith(prefix) for l in self.parent.splitlines()),
                             sum(l.startswith(prefix) for l in result.splitlines()))
        self.assertIn('int_operand_q <= (op == FX_FSCALE) ? operand_b : operand_a;', result)
        self.assertIn("rc_q       <= (op == FX_FSCALE) ? 2'd3 : rc;", result)
        self.assertIn("ri = {1'b0, 1'b0, 64'd0};", result)

    def test_duplicate_missing_and_repeat_refused(self):
        for wrong in (self.parent+self.parent,
                      self.parent.replace('fx_to_int_ex(a_q, 64, rc_q)', 'changed(a_q, 64, rc_q)'),
                      transform(self.parent)):
            with self.assertRaises(ValueError): transform(wrong)

    def test_c1_addition_preserved(self):
        from prepare_fst_memory_c1 import transform_misc
        with_c1 = transform_misc(self.parent)
        result = transform(with_c1)
        self.assertEqual(result.count('rounded_up'), with_c1.count('rounded_up'))
        self.assertEqual(result.count('fx_to_f32_c1('), 1)
        self.assertEqual(result.count('fx_to_f64_c1('), 1)
        self.assertEqual(result.count('fx_to_int_ex('), 1)


if __name__ == '__main__':
    unittest.main()
