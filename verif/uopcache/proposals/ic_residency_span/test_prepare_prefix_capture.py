import unittest

from prepare_prefix_capture import FLAG, OLD, NEW, transform, audit_consumers


class PrefixCapture(unittest.TestCase):
    def setUp(self):
        self.retire = '''task automatic retire_reference_integer;
`ifdef VEN_P54_PREFIX_EX_CHAIN
    if (p54_prefix_ex_take) begin
      // Old instruction still owns this edge.
      capture_reference_decode(next_eip);
      for (int i=0;i<IWORDS*4;i++)
'''+OLD+'''
      fetch_word<=3'd0;
      state<=d_mem_read ? S_LOAD : S_EXEC;
    end
`endif
endtask
'''
        self.core = '''`include "core_ic_prefix_span.svh"
`ifdef VEN_IC_PREFIX_SPAN
        refdecode_ibuf[i] = ic_prefix_bytes[i];
`else
        refdecode_ibuf[i] = ic_byte(p54_prefix_ex_flin + 32'(i));
`endif
'''

    def test_only_nonblocking_byte_rhs_changes(self):
        output = transform(self.retire)
        block = '`ifdef '+FLAG+'\n'+NEW+'\n`else\n'+OLD+'\n`endif'
        self.assertEqual(output.replace(block, OLD), self.retire)
        self.assertEqual(output.replace(block, NEW), self.retire.replace(OLD, NEW))
        audit_consumers(self.core, output)

    def test_refuses_changed_owner_loop_address_or_assignment(self):
        variants = [self.retire+OLD, self.retire.replace(OLD, ''),
                    self.retire.replace('p54_prefix_ex_take', 'other_take'),
                    self.retire.replace('next_eip', 'eip'),
                    self.retire.replace('i<IWORDS*4', 'i<IWORDS*8'),
                    self.retire.replace('ibuf[i]<=', 'ibuf[i]='),
                    self.retire.replace("+32'(i)", "+32'(i+1)"),
                    transform(self.retire)]
        for source in variants:
            with self.subTest(source=source), self.assertRaises(ValueError):
                transform(source)

    def test_refuses_the_original_incomplete_integration(self):
        with self.assertRaises(ValueError):
            audit_consumers(self.core, self.retire)

    def test_refuses_missing_or_duplicate_producer_and_consumer(self):
        fixed = transform(self.retire)
        for core in (self.core.replace('core_ic_prefix_span.svh', 'other.svh'),
                     self.core+self.core, self.core.replace('refdecode_ibuf[i]', 'refdecode_ibuf[i+1]')):
            with self.subTest(core=core), self.assertRaises(ValueError):
                audit_consumers(core, fixed)


if __name__ == '__main__':
    unittest.main()
