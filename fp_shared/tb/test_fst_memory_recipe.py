from pathlib import Path
import unittest
import prepare_fst_memory_c1 as repair

repo=Path(__file__).resolve().parents[2]


class MemoryRecipeTests(unittest.TestCase):
    def test_missing_duplicate_and_reapplication_refused(self):
        for name,fn in repair.TRANSFORMS.items():
            text=(repo/name).read_text()
            for bad in ('',text+text,fn(text)):
                with self.assertRaises(ValueError): fn(bad)

    def test_no_second_conversion_or_added_arithmetic(self):
        text=(repo/'rtl/fpu/fpu_x87_pkg.sv').read_text()
        result=repair.transform_package(text)
        for operation in ("frac + 24'd1", "frac + 53'd1", 'fx_dir_up('):
            self.assertEqual(result.count(operation),text.count(operation))
        for bits,width in ((32,35),(64,67)):
            self.assertIn(f'logic [{width-1}:0] fx_to_f{bits}_ex(',result)
            self.assertIn(f'logic [{width}:0] fx_to_f{bits}_c1(',result)
            self.assertIn(f'return result_with_c1[{width-1}:0]',result)

    def test_registered_sideband_and_existing_latency_unchanged(self):
        text=(repo/'fp_shared/ven_fp_misc.sv').read_text()
        result=repair.transform_misc(text)
        self.assertEqual(result.count('state <='),text.count('state <='))
        self.assertEqual(result.count('done  <='),text.count('done  <='))
        self.assertEqual(result.count('rounded_up <= '),4)
        for bits,width in ((32,35),(64,67)):
            self.assertEqual(result.count(f'rounded_up <= f{bits}[{width}]'),1)

    def test_top_changes_only_misc_owner_and_explicit_wiring(self):
        text=(repo/'fp_shared/ven_fp_top.sv').read_text()
        result=repair.transform_top(text)
        before=text.split('    if ((top_state == TOP_MISC) && misc_done) begin')[1]
        after=result.split('    if ((top_state == TOP_MISC) && misc_done) begin')[1]
        marker='    if ((top_state == TOP_BCD_LOAD) && bcd_load_done) begin'
        self.assertEqual(before.split(marker)[1],after.split(marker)[1])
        self.assertEqual(result.count('c_status_data[9] = misc_rounded_up'),1)
        self.assertEqual(result.count('(pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80})'),2)


if __name__=='__main__': unittest.main()
