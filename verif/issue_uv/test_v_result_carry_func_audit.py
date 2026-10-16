import unittest

from audit_v_result_carry_func import derive


class FunctionalAudit(unittest.TestCase):
    def test_full_comparison_and_no_false_canonical_pass(self):
        text = derive()
        for check in ('len(goldens)==108', 'count==80800 and paired==30132',
                      "compare.main(['--mode','func','--all',*args",
                      "compare.main(['--mode','func','--all',str(golden)",
                      "['tx_regform','tx_regform2','tx_stack']", 'canonical_gate_passed=False',
                      'hardware_acceptance=False', 'same_elf_except_gcc_file_symbol',
                      "'fresh reference required'"):
            self.assertIn(check, text)

    def test_native_closure_and_new_affinity_required(self):
        text = derive()
        self.assertIn("owner['InvocationID'] == start['invocation']", text)
        self.assertIn("owner['SubState']=='exited' and owner['MainPID']=='0'", text)
        self.assertIn('cpu in range(12,16)', text)
        self.assertIn('ventium-v-result-carry-func-oct16-r1.service', text)


if __name__ == '__main__':
    unittest.main()
