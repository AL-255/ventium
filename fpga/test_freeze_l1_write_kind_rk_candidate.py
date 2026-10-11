import unittest
import freeze_l1_write_kind_rk_candidate as freeze
import test_freeze_fld_c1_rk_candidate as previous


class WriteKindFreeze(unittest.TestCase):
    def setUp(self):
        fixture=previous.LoadC1Freeze(); fixture.setUp()
        self.native,self.hardware=fixture.native,fixture.hardware

    def test_exact_profile(self):
        self.assertEqual(freeze.profile(self.hardware,self.native),self.hardware)
        self.assertEqual(set(freeze.DELTAS),{'rtl/mem/ven_l1d.sv'})

    def test_profile_drift_rejected(self):
        for flag in self.native:
            for replacement in ([],['VEN_UNKNOWN'],['VEN_CACHE_HALF']):
                with self.subTest(flag=flag),self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.hardware,[v for v in self.native if v!=flag]+replacement)
        with self.assertRaises(freeze.FreezeError):
            freeze.profile(self.hardware,self.native+self.native[:1])

    def test_fast_features_retained(self):
        for flag in ('VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
                     'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FP_SHARED'):
            with self.subTest(flag=flag),self.assertRaises(freeze.FreezeError):
                freeze.profile([v if v!=flag else 'UNKNOWN' for v in self.hardware],
                               [v if v!=flag else 'UNKNOWN' for v in self.native])

    def test_only_exact_one_file_delta(self):
        for name,digest in freeze.DELTAS.items():
            self.assertTrue(freeze.check_delta(name,'old',digest))
            self.assertFalse(freeze.check_delta(name,digest,digest))
            for bad,d in ((name,'wrong'),('rtl/core/core_mem_chain.svh',digest),
                          ('flow/create_project.tcl',digest)):
                with self.subTest(name=bad),self.assertRaises(freeze.FreezeError):
                    freeze.check_delta(bad,'old',d)


if __name__=='__main__': unittest.main()
