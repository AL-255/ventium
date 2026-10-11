import os
from pathlib import Path
import tempfile
import unittest
import freeze_timing_combo_rk_candidate as freeze
import test_freeze_fld_c1_rk_candidate as previous


class TimingComboFreeze(unittest.TestCase):
    def setUp(self):
        fixture=previous.LoadC1Freeze(); fixture.setUp()
        self.native,self.hardware=fixture.native,fixture.hardware

    def test_exact_profile(self):
        self.assertEqual(freeze.profile(self.hardware,self.native),self.hardware)
        self.assertEqual(set(freeze.DELTAS),{'rtl/core/core_mem_chain.svh',
            'rtl/fpu/fpu_srt_div.sv','rtl/mem/ven_l1d.sv'})

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

    def test_only_exact_three_file_delta(self):
        for name,digest in freeze.DELTAS.items():
            self.assertTrue(freeze.check_delta(name,'old',digest))
            self.assertFalse(freeze.check_delta(name,digest,digest))
            for bad,d in ((name,'wrong'),('rtl/fpu/fpu_top.sv',digest),
                          ('flow/create_project.tcl',digest)):
                with self.subTest(name=bad),self.assertRaises(freeze.FreezeError):
                    freeze.check_delta(bad,'old',d)
            for other,wrong_digest in freeze.DELTAS.items():
                if other != name:
                    with self.subTest(name=name,other=other),self.assertRaises(freeze.FreezeError):
                        freeze.check_delta(name,'old',wrong_digest)

    def test_observation_does_not_retain_payload(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            path=Path(directory).resolve()/'input'
            path.write_bytes(b'original bytes')
            observed={}
            info=freeze.read_observed(observed,path)
            self.assertEqual(info['data'],b'original bytes')
            self.assertEqual(set(observed[path]),{'sha256','bytes','fingerprint'})
            self.assertEqual(freeze.read_observed(observed,path),info)
            freeze.unchanged(path,observed[path])
            with self.assertRaises(freeze.FreezeError):
                freeze.read_observed(observed,path,'0'*64)
            path.write_bytes(b'different bytes')
            with self.assertRaises(freeze.FreezeError):
                freeze.read_observed(observed,path)
            with self.assertRaises(freeze.FreezeError):
                freeze.unchanged(path,observed[path])

    def test_same_bytes_replaced_file_rejected(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            path=Path(directory).resolve()/'input'
            replacement=path.with_name('replacement')
            path.write_bytes(b'same bytes')
            observed={}
            freeze.read_observed(observed,path)
            replacement.write_bytes(b'same bytes')
            replacement.replace(path)
            with self.assertRaises(freeze.FreezeError):
                freeze.read_observed(observed,path)
            with self.assertRaises(freeze.FreezeError):
                freeze.unchanged(path,observed[path])


if __name__=='__main__': unittest.main()
