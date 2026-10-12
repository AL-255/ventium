"""Independent boundary checks for the narrowing diagnostic, not RTL acceptance."""
from fractions import Fraction as F
import unittest

from check_remaining_c1 import binary32, classify, store_c1


class NarrowingTests(unittest.TestCase):
    def test_binary32(self):
        self.assertEqual(binary32(0x3f800000), 1)
        self.assertEqual(binary32(0xbf800000), -1)
        self.assertEqual(binary32(1), F(1, 1 << 149))
        self.assertEqual(binary32(0x80800000), -F(1, 1 << 126))
        with self.assertRaises(AssertionError):
            binary32(0x7f800000)

    def test_exact(self):
        for p, emin, emax in ((24, -126, 127), (53, -1022, 1023)):
            for rc in range(4):
                for v in (0, 1, -1, F(1, 1 << (-emin+p-1))):
                    self.assertEqual(store_c1(v, p, emin, emax, rc), 0)

    def test_ties_both_signs(self):
        for p, emin, emax in ((24, -126, 127), (53, -1022, 1023)):
            for sign in (-1, 1):
                self.assertEqual(store_c1(sign*(1+F(1, 1 << p)), p, emin, emax, 0), 0)
                self.assertEqual(store_c1(sign*(1+F(3, 1 << p)), p, emin, emax, 0), 1)

    def test_directed(self):
        for rc in range(4):
            self.assertEqual(store_c1(1+F(1, 1 << 60), 24, -126, 127, rc), int(rc == 2))
            self.assertEqual(store_c1(-1-F(1, 1 << 60), 24, -126, 127, rc), int(rc == 1))

    def test_subnormal(self):
        self.assertEqual(store_c1(F(1, 1 << 150), 24, -126, 127, 0), 0)
        self.assertEqual(store_c1(F(3, 1 << 150), 24, -126, 127, 0), 1)
        self.assertEqual(store_c1(F(1, 1 << 200), 24, -126, 127, 2), 1)

    def test_overflow(self):
        for p, emin, emax in ((24, -126, 127), (53, -1022, 1023)):
            for sign in (-1, 1):
                for rc in range(4):
                    expected = int(rc == 0 or (rc == 1 and sign < 0) or (rc == 2 and sign > 0))
                    self.assertEqual(store_c1(sign*(1 << (emax+4)), p, emin, emax, rc), expected)
            edge = F(1 << (emax+1)) - F(1 << (emax-p))
            self.assertEqual(store_c1(edge, p, emin, emax, 0), 1)
            self.assertEqual(store_c1(edge, p, emin, emax, 3), 0)

    def test_unknown_instruction_fails_closed(self):
        with self.assertRaises(AssertionError):
            classify(dict(instruction_prefix='90', before=dict(fstat='0', fxsave_tag='0'),
                          after=dict(fstat='0')))

    def test_wait_is_not_following_fninit(self):
        fp = dict(fstat='0x0220', fctrl='0x037f', fxsave_tag='0')
        witness = dict(instruction_prefix='9bdbe3', before=fp, after=fp.copy(),
                       gprs_before=dict(eip='0x100'), gprs_after=dict(eip='0x101'))
        self.assertEqual(classify(witness), ('observed_retention', None))
        witness['gprs_after']['eip'] = '0x103'
        with self.assertRaises(AssertionError):
            classify(witness)

    def test_wait_rejects_pending_unmasked(self):
        fp = dict(fstat='0x0001', fctrl='0x037e', fxsave_tag='0')
        with self.assertRaises(AssertionError):
            classify(dict(instruction_prefix='9b', before=fp, after=fp.copy(),
                          gprs_before=dict(eip='0x100'), gprs_after=dict(eip='0x101')))


if __name__ == '__main__':
    unittest.main()
