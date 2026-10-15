"""Fresh reference runner bindings and unchanged manifest-mask boundaries."""
import unittest

import run_fetch_pair_next_func as runner
from audit_fetch_pair_next_func import ROOT, mask_args, same_elf_except_gcc_file_symbol


class FreshFunctional(unittest.TestCase):
    def test_native_runner(self):
        text = runner.derive()
        self.assertIn(runner.MODEL, text)
        self.assertIn(runner.ORACLE, text)
        self.assertIn("VTM_QEMU_GDB_PREEXIT='1'", text)
        self.assertIn("TB_EXTRA_FLAGS='--cycle-func --l1-axi'", text)
        self.assertIn('fresh_qemu=True,authenticated_input_replay=False', text)
        self.assertNotIn('qualify_tooling', text)
        self.assertIn('canonical_gate_passed=False', text)

    def test_no_new_masks(self):
        self.assertEqual(mask_args({}), [])
        self.assertEqual(mask_args({'x87':True}), [])

    def test_exact_manifest_ranges(self):
        self.assertEqual(mask_args({'x87_stkflt_fstat_ranges':[[3,4]],
            'x87_stkflt_fpr_ranges':[[5,None,'st0,st3']]}), [
                '--mask-fstat-exc','0x4741','--mask-fstat-range','3:4',
                '--mask-fpr-range','5:=st0,st3'])
        self.assertEqual(mask_args({'x87_fprem1_cc_ranges':[[2,2]]}), [
            '--mask-fstat-exc','0x4300','--mask-fstat-range','2:2'])

    def test_only_nonloadable_file_name_may_differ(self):
        before = (ROOT/'fetch-pair-next-core-r1/generic-work/mb_agi.func.elf').read_bytes()
        after = (ROOT/'fetch-pair-next-freshfunc-r1/work/mb_agi.func.elf').read_bytes()
        self.assertGreater(same_elf_except_gcc_file_symbol(before, after),0)
        for offset in (24, 4096):  # Entry address and first executable byte.
            bad = bytearray(after)
            bad[offset] ^= 1
            with self.assertRaises(AssertionError):
                same_elf_except_gcc_file_symbol(before,bytes(bad))


if __name__ == '__main__':
    unittest.main()
