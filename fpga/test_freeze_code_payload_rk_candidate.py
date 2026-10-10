"""Exact code payload extension and seven FP correctness backports; no source/profile substitutions."""
import unittest
import freeze_code_payload_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class CodePayloadProfile(unittest.TestCase):
    def setUp(self):
        self.parent=[f'BASE_{i}' for i in range(132)]+['VEN_SFETCH16_DEMAND']+list(
            freeze.PARENT_EXTRA)+['VEN_IC_RESIDENCY_SPAN','VEN_IC_PREFIX_SPAN',
            'VEN_CACHEINV_LOCAL','VEN_FP_PIPE_PAYLOAD_SELECT',
            'VEN_SRT_PAYLOAD_SELECT','VEN_FP_LOAD_PAYLOAD_SELECT','VEN_FP_LOAD64_PAYLOAD_SELECT',
            'VEN_L1D_RESPONSE_PAYLOAD_SELECT','VEN_L1D_HIGH_PAYLOAD_SELECT','SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        self.sim=sorted(set(self.parent)-{'SYNTHESIS','VTM_NO_DPI'}|{'VEN_L1D_CODE_PAYLOAD_SELECT'})

    def test_exact_extension(self):
        self.assertEqual(freeze.profile(self.parent,self.sim),
                         self.parent[:-3]+['VEN_L1D_CODE_PAYLOAD_SELECT']+self.parent[-3:])

    def test_missing_or_replaced_features_refused(self):
        for name in self.sim:
            for replacement in ([],['VEN_UNKNOWN'],['VEN_UOPCACHE'],['VEN_CACHE_HALF']):
                with self.subTest(name=name),self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.parent,[x for x in self.sim if x!=name]+replacement)

    def test_duplicates_refused(self):
        for a,b in ((self.parent+self.parent[:1],self.sim),(self.parent,self.sim+self.sim[:1]),
                    (self.parent,self.sim[1:]+self.sim[1:2])):
            with self.assertRaises(freeze.FreezeError):freeze.profile(a,b)

    def test_parent_order_drift_refused(self):
        for i in range(132,154):
            altered=list(self.parent);altered[i],altered[i+1]=altered[i+1],altered[i]
            with self.subTest(i=i),self.assertRaises(freeze.FreezeError):
                freeze.profile(altered,self.sim)

    def test_hardware_projection_unchanged(self):
        fixture=parent_tests.Contracts();fixture.setUp()
        hardware=fixture.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')
        self.assertEqual(freeze.projection(hardware,fixture.sim),hardware)
        with self.assertRaises(freeze.FreezeError):freeze.projection(hardware,fixture.sim+b'// drift\n')

    def test_exact_source_delta(self):
        expected={
            'rtl/fpu/fpu_srt_div.sv': '4981be7041c2e67cca1b216ca486596bc327bd102f6e8278b172e669ee159c11',
            'rtl/fpu/fpu_x87_pkg.sv': '311d30545302569c05f9332b372b253b43e354943826c9089f4cc6f04329e27a',
            'fp_shared/ven_fp_alu.sv': 'b71624307bb332044b7b04aebb303f51a4a6b7f9bf45243577c349669bbeeb14',
            'fp_shared/ven_fp_top.sv': '282c34f72238701480bbb75321ecb8884b227f0a606a603e1bd284adf97f86e1',
            'rtl/core/core.sv': '38e5f290d4888548cbe4f86f9f2f1ce7b3074b196f5b7039ce41900a93187dd7',
            'rtl/core/fpu_writeback.sv': '22e3f29b001656beb6d0062de5652acbdd5aadbd489e1c6fa30a2d1a6df497f6',
            'fp_shared/ven_fp_misc.sv': '4ac4e9d37dc57f6af3fd2babe41a13df5069a2797ab7b6dd8b811ff511fe0161',
            'rtl/mem/ven_l1d.sv': '2c6821f396d081bf30916a7ad48505512aa3477f649cec2ce25f3e621d0a133b',
        }
        self.assertEqual(freeze.CHANGES,expected)


if __name__=='__main__':unittest.main()
