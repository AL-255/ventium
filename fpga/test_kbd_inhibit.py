import unittest
import prepare_kbd_inhibit as recipe
import run_kbd_inhibit_fixed as fixed


class InhibitRepairTests(unittest.TestCase):
    def test_exact_no_storage_repair(self):
        original=recipe.witness.INJECTOR.read_text();changed=recipe.transform(original)
        self.assertEqual(changed.count('reg '),original.count('reg '))
        self.assertIn('bit_idx == 4\'d10 && half_count > HALF_CYCLES',changed)
        self.assertIn('else\n                            state <= WAIT_IDLE;',changed)
        self.assertIn('end else if (half_count == CELL_CYCLES',changed)
        with self.assertRaises(AssertionError):recipe.transform(changed)
        with self.assertRaises(AssertionError):recipe.transform(original+'\n')

    def test_same_matrix_requires_positive_exit(self):
        text=fixed.derive()
        self.assertIn('range(23)',text)
        self.assertIn('good=(code==0',text)
        self.assertNotIn('good=(code==1',text)
        self.assertIn('child.wait(timeout=12)',text)
        self.assertIn('candidate_matrix_passed=good,endpoint_contract_only=True',text)


if __name__=='__main__':unittest.main()
