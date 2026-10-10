"""Fail-closed source-recipe checks; native RTL tests remain required."""
from pathlib import Path
import unittest
import prepare_fp_correctness_bundle as bundle
import prepare_fst_unmasked as repair


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        repo = Path(__file__).resolve().parents[2]
        files = {n: (repo/n).read_text() for n in bundle.FILES}
        name = bundle.arithmetic.FILES[0]
        files[name] = bundle.arithmetic.floor.transform(files[name])
        files = bundle.transform(files)
        cls.inputs = {n: files[n] for n in repair.TRANSFORMS}

    def test_only_two_files_and_no_input_mutation(self):
        before = dict(self.inputs)
        output = repair.transform(self.inputs)
        self.assertEqual(self.inputs, before)
        self.assertEqual(set(output), set(before))
        self.assertTrue(all(output[n] != before[n] for n in before))

    def test_no_converter_or_state_added(self):
        output = repair.transform(self.inputs)
        for n in output:
            for pattern in ('fx_to_f32_c1(', 'fx_to_f64_c1(', 'M_EXEC:', 'M_DONE:',
                            'TOP_MISC:', 'TOP_IDLE:', 'always_ff', 'always_comb'):
                self.assertEqual(output[n].count(pattern), self.inputs[n].count(pattern))
        misc = output['fp_shared/ven_fp_misc.sv']
        self.assertEqual(misc.count('tiny_nonzero <='), 4)

    def test_both_memory_and_pop_have_same_guard(self):
        top = repair.transform(self.inputs)['fp_shared/ven_fp_top.sv']
        self.assertEqual(top.count('rsp_store_valid <= !misc_fst_range_block;'), 1)
        self.assertEqual(top.count("c_pop = (pending_pop && !misc_fst_range_block) ? 2'd1 : 2'd0;"), 1)
        self.assertNotIn('misc_pe && !fctrl_o[5]', top)

    def test_repeated_missing_or_partial_input_rejected(self):
        output = repair.transform(self.inputs)
        with self.assertRaises(ValueError):
            repair.transform(output)
        with self.assertRaises(ValueError):
            repair.transform({})
        for n in self.inputs:
            partial = dict(self.inputs); partial[n] = output[n]
            with self.subTest(name=n), self.assertRaises(ValueError):
                repair.transform(partial)

    def test_missing_late_owner_does_not_mutate_inputs(self):
        wrong = dict(self.inputs)
        wrong['fp_shared/ven_fp_top.sv'] = wrong['fp_shared/ven_fp_top.sv'].replace(
            "              rsp_store_valid <= 1'b1;", '// absent')
        before = dict(wrong)
        with self.assertRaises(ValueError):
            repair.transform(wrong)
        self.assertEqual(wrong, before)


if __name__ == '__main__':
    unittest.main()
