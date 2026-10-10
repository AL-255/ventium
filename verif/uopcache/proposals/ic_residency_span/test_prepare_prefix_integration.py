import unittest
from prepare_prefix_integration import FLAG, HEADER, OLD, transform


class Preparation(unittest.TestCase):
    def setUp(self):
        self.text = '''localparam int IWORDS = 4;
function automatic logic [IC_WAYW:0] ic_front_probe(input logic [31:0] addr);
endfunction
  // END IC FRONT SPAN
for (int i=0; i<IWORDS*4; i++) begin
`ifdef VEN_P54_PREFIX_EX_CHAIN
      // State-only original selection.
      if (state == S_EXEC)
'''+OLD+'''
      else
        refdecode_ibuf[i] = ibuf[i];
`endif
end
'''

    def test_exact_default_off(self):
        output = transform(self.text)
        self.assertEqual(output.count('`ifdef '+FLAG), 2)
        self.assertEqual(output.count(OLD), 1)
        self.assertEqual(output.count('`include "'+HEADER+'"'), 1)
        self.assertIn('if (state == S_EXEC)\n`ifdef '+FLAG, output)
        self.assertIn('`endif\n      else\n', output)

    def test_refuses_drift(self):
        variants = [self.text+OLD, self.text.replace(OLD,''),
                    self.text.replace('IWORDS = 4','IWORDS = 8'),
                    self.text.replace('state == S_EXEC','permit'),
                    self.text.replace('i<IWORDS*4','i<IWORDS*8'),
                    self.text.replace('ic_front_probe(', 'other_probe('),
                    transform(self.text)]
        for variant in variants:
            with self.subTest(variant=variant):
                with self.assertRaises(ValueError):
                    transform(variant)


if __name__ == '__main__':
    unittest.main()
