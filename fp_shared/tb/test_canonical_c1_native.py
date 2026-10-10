#!/usr/bin/env python3
import unittest

from check_canonical_c1_native import binary64, exact_operation


def witness(code, a, b, result, **extra):
    return dict(instruction_prefix=code, before=dict(st=[f'{a:020x}', f'{b:020x}']),
                after=dict(st=[f'{result:020x}']), **extra)


class ExactCanonicalCases(unittest.TestCase):
    def test_reverse_divide_uses_opcode_not_source_comment(self):
        w = witness('def1000000000000', 0x4000c000000000000000,
                    0x4002a000000000000000, 0x3ffd999999999999999a)
        got = exact_operation(w)
        self.assertEqual((got['exact_numerator_hex'], got['exact_denominator_hex']), ('0x3', '0xa'))
        self.assertEqual((got['exact_c1'], got['exact_inexact']), (1, 1))

    def test_exact_divide_clears_round_direction(self):
        got = exact_operation(witness('d8f1000000000000', 0x40029000000000000000,
                                      0x40008000000000000000, 0x40019000000000000000))
        self.assertEqual((got['exact_c1'], got['exact_inexact']), (0, 0))

    def test_finite_overflow_to_infinity(self):
        got = exact_operation(witness('dec9000000000000', 0x70008000000000000000,
                                      0x70008000000000000000, 0x7fff8000000000000000))
        self.assertEqual((got['exact_c1'], got['exact_inexact']), (1, 1))

    def test_exact_square_root(self):
        got = exact_operation(witness('d9fa000000000000', 0x40038000000000000000,
                                      0, 0x40018000000000000000))
        self.assertEqual((got['exact_c1'], got['exact_inexact']), (0, 0))

    def test_binary64_memory_subtract(self):
        w = witness('dc25309004080000', 0x40018000000000000000, 0,
                    0x40008000000000000000,
                    operand_address='0x08049030', operand_bits64='4000000000000000')
        self.assertEqual(binary64(0x4000000000000000), 2)
        self.assertEqual(exact_operation(w)['exact_c1'], 0)

    def test_unknown_opcode_refused(self):
        with self.assertRaises(AssertionError):
            exact_operation(witness('9090000000000000', 0, 0, 0))


if __name__ == '__main__':
    unittest.main()
