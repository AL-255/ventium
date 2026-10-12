"""Fail-closed source recipe and structural data-cone contracts."""
import os
from pathlib import Path
import unittest
from prepare_memdiv_capture import transform


class MemoryDivideCapture(unittest.TestCase):
    def source(self):
        return Path(os.environ['MEMDIV_PARENT_TOP']).read_text()

    def test_drift_rejected(self):
        source = self.source()
        for invalid in (source+'\n', transform(source)):
            with self.assertRaises(ValueError): transform(invalid)

    def test_no_live_memory_divide_input(self):
        new = transform(self.source())
        operand = new[new.index('    div_aluop = cmd_aluop;'):new.index('  logic [81:0] div_special_raw;')]
        self.assertNotIn('cmd_mem', operand)
        self.assertNotIn('alu_a', operand)
        self.assertNotIn('alu_b', operand)
        special = new[new.index('    div_special_raw    ='):new.index('    sqrt_special_hit    =')]
        self.assertNotIn('alu_a', special)
        self.assertNotIn('alu_b', special)
        self.assertNotIn('cmd_mem', special)
        self.assertEqual(new.count('div_mem_q   <= cmd_mem;'), 1)
        self.assertEqual(new.count('srt_start = !div_special_hit;'), 2)
        self.assertEqual(new.count('is_div_arith(cmd_aluop) && !mem_arith_cmd && !div_special_hit'), 2)
        self.assertIn('TOP_TRANS, TOP_MEMDIV', new)
        self.assertIn('fp_perf_state [8]', new)

    def test_other_arithmetic_and_controls_unchanged(self):
        source = self.source(); new = transform(source)
        for begin, end in (
            ('  // Operand selection mirrors', '  // A single shared compare'),
            ('  // Rounding controls are live', '`ifdef VEN_SRT_PAYLOAD_SELECT'),
            ('        TOP_ALU: begin', '        TOP_MEMDIV: begin'),
        ):
            old_end = '        TOP_SRT: begin' if end.endswith('TOP_MEMDIV: begin') else end
            self.assertEqual(new[new.index(begin):new.index(end)],
                             source[source.index(begin):source.index(old_end)])


if __name__ == '__main__': unittest.main()
