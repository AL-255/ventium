import unittest

import freeze_zero_c1_rk_candidate as freeze
import test_freeze_fld_c1_rk_candidate as previous


class ZeroC1Freeze(unittest.TestCase):
    def setUp(self):
        fixture = previous.LoadC1Freeze()
        fixture.setUp()
        self.native, self.hardware = fixture.native, fixture.hardware

    def test_exact_unchanged_uv_fast_profile(self):
        self.assertEqual(freeze.profile(self.hardware, self.native), self.hardware)
        self.assertEqual(set(freeze.DELTAS), {
            'fp_shared/ven_fp_top.sv', 'rtl/fpu/fpu_x87_pkg.sv', 'rtl/fpu/ven_bcd_to_fp.sv'})

    def test_feature_drift_rejected(self):
        for feature in self.native:
            for replacement in ([], ['VEN_UNKNOWN'], ['VEN_CACHE_HALF']):
                with self.subTest(feature=feature), self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.hardware, [v for v in self.native if v != feature]+replacement)
        with self.assertRaises(freeze.FreezeError):
            freeze.profile(self.hardware, self.native+self.native[:1])

    def test_required_features_cannot_be_removed_from_both_profiles(self):
        for feature in ('VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                        'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_SHARED'):
            with self.subTest(feature=feature), self.assertRaises(freeze.FreezeError):
                freeze.profile([v if v != feature else 'UNKNOWN' for v in self.hardware],
                               [v if v != feature else 'UNKNOWN' for v in self.native])

    def test_only_exact_three_payload_digests(self):
        for name, digest in freeze.DELTAS.items():
            self.assertTrue(freeze.check_delta(name, 'old', digest))
            self.assertFalse(freeze.check_delta(name, digest, digest))
            for wrong_name, wrong_digest in ((name, 'unknown'), ('rtl/core/core.sv', digest),
                                            ('flow/create_project.tcl', digest)):
                with self.subTest(name=wrong_name), self.assertRaises(freeze.FreezeError):
                    freeze.check_delta(wrong_name, 'old', wrong_digest)
        self.assertFalse(freeze.check_delta('rtl/core/core.sv', 'same', 'same'))


if __name__ == '__main__':
    unittest.main()
