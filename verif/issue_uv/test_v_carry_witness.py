"""Pair witness regression: U is not required to carry V's paired marker."""
import unittest
from run_v_carry_system_r2 import check_pair_witness


class Witness(unittest.TestCase):
    def setUp(self):
        self.u = dict(n=100, pc='0x000f02e5', cyc=2061, pipe='U', paired=False)
        self.v = dict(n=101, pc='0x000f02e8', cyc=2061, pipe='V', paired=True)

    def test_observed_pair(self):
        check_pair_witness(self.u, self.v, 0xf02e5)

    def test_reject_invalid_witnesses(self):
        for side, key, value in (
            ('u', 'pipe', 'V'), ('u', 'pc', '0x000f02e0'),
            ('u', 'n', 99), ('u', 'cyc', 2060),
            ('v', 'pipe', 'U'), ('v', 'paired', False),
        ):
            with self.subTest(side=side, key=key):
                u, v = self.u.copy(), self.v.copy()
                (u if side == 'u' else v)[key] = value
                with self.assertRaises(AssertionError):
                    check_pair_witness(u, v, 0xf02e5)


if __name__ == '__main__':
    unittest.main()
