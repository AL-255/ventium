import unittest
from prepare_fst_legacy_tb import generate

WB='''// ===== INPUTS
    input state_e state,
    input fxop_e q_fxop,
    input logic pipe_fp_live_arm,
`ifdef VEN_FP_PIPE
    input logic [79:0] data [8],
`endif
    output logic fp_we_fstat,
    output logic fp_we_sti
);
'''
CORE='typedef enum logic { S_RESET } state_e;\nmodule core; endmodule\n'
BODY='initial begin\n  // GENERATED_INPUT_DEFAULTS\nend'

class LegacyShellTests(unittest.TestCase):
    def test_exact_types_no_writeback_substitution(self):
        prefix,shell=generate(WB,CORE,BODY)
        self.assertEqual(prefix,CORE.split('module core')[0])
        self.assertIn('fpu_writeback dut (.*);',shell)
        self.assertIn("state = state_e'('0);",shell)
        self.assertIn("foreach (data[i]) data[i] = '0;",shell)
        self.assertNotIn("fp_we_fstat =",shell)
        self.assertEqual(shell.count('`ifdef VEN_FP_PIPE'),2)

    def test_missing_and_ambiguous_prefix_refused(self):
        for core in ('module core;','module core;\n'+CORE,CORE.replace('state_e','other_e')):
            with self.assertRaises(ValueError): generate(WB,core,BODY)

    def test_unrecognized_or_duplicate_port_refused(self):
        for wb in (WB.replace('input state_e state,','input state_e state = 0,'),
                   WB.replace('input fxop_e q_fxop,','input state_e state,'),
                   WB.replace('pipe_fp_live_arm','different_name')):
            with self.assertRaises(ValueError): generate(wb,CORE,BODY)

    def test_missing_and_duplicate_defaults_refused(self):
        for body in ('',BODY+BODY):
            with self.assertRaises(ValueError): generate(WB,CORE,body)

if __name__=='__main__': unittest.main()
