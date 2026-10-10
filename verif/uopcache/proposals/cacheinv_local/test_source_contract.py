import unittest
from audit_source_contract import audit, select_defines

CORE = '''localparam int IWORDS = 4;
logic [7:0] ibuf [16];
assign cache_inv_go = d_cacheinv && (state == S_DECODE) && !d_unknown;
refdecode_valid = ((state == S_FETCH) && sfetch_boundary) ? sfetch_valid_q : 5'd16;
  logic [7:0] refdecode_ibuf [IWORDS*4];
always_comb begin
for (int i=0; i<IWORDS*4; i++) begin
`ifdef VEN_P54_PREFIX_EX_CHAIN
if (state == S_EXEC)
`ifdef VEN_IC_PREFIX_SPAN
refdecode_ibuf[i] = ic_prefix_bytes[i];
`else
refdecode_ibuf[i] = ic_byte(p54_prefix_ex_flin + 32'(i));
`endif
else
`endif
`ifdef VEN_IC_BRAM
refdecode_ibuf[i] = (state == S_PIPE) ? ic_front_bytes[i] : ibuf[i];
`else
refdecode_ibuf[i] = (state == S_PIPE) ? ic_byte(flin + 32'(i)) : ibuf[i];
`endif
end
end
`endif
  decode_stages u_decode_stages (
'''
DEFINES = {'VEN_PIPE_SDISPATCH', 'VEN_P54_PREFIX_EX_CHAIN', 'VEN_IC_PREFIX_SPAN', 'VEN_IC_BRAM'}


class Contract(unittest.TestCase):
    def test_expected_mux(self):
        self.assertTrue(audit(CORE, DEFINES)['decode_state_uses_registered_bytes'])

    def test_drift(self):
        for old, new in [('state == S_EXEC', 'state == S_DECODE'),
                         ('state == S_FETCH', 'state == S_DECODE'),
                         ("5'd16", "5'd15"), ('!d_unknown', '!different'),
                         ('IWORDS = 4', 'IWORDS = 8'), ('ibuf[i];', 'live[i];')]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                audit(CORE.replace(old, new), DEFINES)

    def test_profile(self):
        for flag in DEFINES:
            with self.subTest(flag=flag), self.assertRaises(ValueError):
                audit(CORE, DEFINES - {flag})

    def test_bad_directives(self):
        for text in ['`endif', '`ifdef X', '`else', '`include "x"',
                     '`ifdef X\n`else\n`else\n`endif']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                select_defines(text, {'X'})


if __name__ == '__main__':
    unittest.main()
