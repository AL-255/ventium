import unittest
from pathlib import Path
from prepare_bcd_sign import engine, package

class BcdSign(unittest.TestCase):
    def test_engine_one_edge_unchanged(self):
        root=Path(__file__).resolve().parents[2]
        source=(root/'rtl/fpu/ven_bcd_to_fp.sv').read_text()
        fixed=engine(source)
        self.assertNotIn('sign_q ? -$signed(mag)',fixed)
        self.assertIn("result_q <= {sign_q, magnitude_fp[78:0]};",fixed)
        self.assertEqual(source.count('st <='),fixed.count('st <='))
        self.assertEqual(source.count('done_q'),fixed.count('done_q'))
        for bad in ('',fixed,source+source):
            with self.assertRaises(ValueError):engine(bad)

    def test_function_scope(self):
        root=Path(__file__).resolve().parents[2]
        source=(root/'rtl/fpu/fpu_x87_pkg.sv').read_text();fixed=package(source)
        begin=source.index('  function automatic logic [79:0] fx_bcd_to_fx(')
        end=source.index('  endfunction',begin)
        newend=fixed.index('  endfunction',begin)
        self.assertEqual(source[:begin],fixed[:begin])
        self.assertEqual(source[end:],fixed[newend:])
        self.assertIn('fx_bcd_to_fx = {bcd[79], magnitude_fp[78:0]};',fixed)
        for bad in ('',fixed,source+source):
            with self.assertRaises(ValueError):package(bad)

if __name__=='__main__':unittest.main()
