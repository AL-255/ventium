import os
from pathlib import Path
import unittest

import prepare_prefix_opcode as recipe
from run_prefix_opcode import fixture


class PrefixOpcodeFixtureTests(unittest.TestCase):
    def setUp(self):
        self.source=(Path(os.environ['PREFIX_OPCODE_PARENT'])/recipe.FILE).read_text()

    def test_full_output_comparison_and_real_mutants(self):
        text,count=fixture(self.source)
        self.assertEqual(count,122)
        self.assertEqual(text.count('PREFIX-OPCODE-MISMATCH'),122)
        for name in ('d_fetch_need','d_fetch_fault_len','d_unknown','d_imm','d_ea',
                     'd_sysop','d_lock','d_fxop','d_addr_mask_known','d_pfx_seg_idx'):
            self.assertIn(f'if (p_{name} !== ((mutant==1)?b_{name}:((mutant==2)?s_{name}:f_{name})))',text)
        for version in ('parent','fixed','bad_end','bad_second'):
            self.assertIn(f'decode_stages_{version} {version}(',text)
        self.assertIn('ibuf [16]',text)
        self.assertIn('gpr  [NUM_GPR]',text)

    def test_unparsed_port_rejected(self):
        bad=self.source.replace('output logic        d_halt,','output logic d_halt [1][2],')
        with self.assertRaises(ValueError): fixture(bad)

    def test_duplicate_port_rejected(self):
        bad=self.source.replace('output logic        d_halt,','output logic d_unknown,')
        with self.assertRaises(AssertionError): fixture(bad)


if __name__=='__main__': unittest.main()
