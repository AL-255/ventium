"""Host checks for the exact-integer quotient oracle and negative result gate."""
import unittest

from audit_memdiv_erratum import require_value
from run_memdiv_erratum import rounded80


class QuotientOracleTests(unittest.TestCase):
    def test_exact_and_canonical(self):
        self.assertEqual(rounded80(1,1),0x3fff8000000000000000)
        self.assertEqual(rounded80(1,2),0x3ffe8000000000000000)
        self.assertEqual(rounded80(2,1),0x40008000000000000000)
        self.assertEqual(rounded80(4195835,3145727),0x3fffaabaa0e3e35a14bd)

    def test_ties_even_and_exponent_carry(self):
        self.assertEqual(rounded80((1<<64)+1,1<<64),0x3fff8000000000000000)
        self.assertEqual(rounded80((1<<64)+3,1<<64),0x3fff8000000000000002)
        self.assertEqual(rounded80((1<<65)-1,1<<64),0x40008000000000000000)

    def test_expected_result_is_required(self):
        clean=0x3fffaabaa0e3e35a14bd
        records=[dict(pc='0x08048010',st0=hex(clean))]
        require_value(records,0x8048010,clean)
        with self.assertRaises(AssertionError): require_value(records,0x8048010,0x3fffaab7f6392a768638)
        with self.assertRaises(AssertionError): require_value(records,0x8048011,clean)
        with self.assertRaises(AssertionError): require_value(records*2,0x8048010,clean)


if __name__=='__main__': unittest.main()
