"""Exact saved-window upper-word payload extension; no source/profile substitutions."""
import unittest
import freeze_high_window_payload_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class HighWindowPayloadProfile(unittest.TestCase):
    def setUp(self):
        self.parent=[f'BASE_{i}' for i in range(132)]+['VEN_SFETCH16_DEMAND']+list(
            freeze.PARENT_EXTRA)+['VEN_IC_RESIDENCY_SPAN','VEN_IC_PREFIX_SPAN',
            'VEN_CACHEINV_LOCAL','VEN_FP_PIPE_PAYLOAD_SELECT',
            'VEN_SRT_PAYLOAD_SELECT','VEN_FP_LOAD_PAYLOAD_SELECT','VEN_FP_LOAD64_PAYLOAD_SELECT',
            'VEN_L1D_RESPONSE_PAYLOAD_SELECT','SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        self.sim=sorted(set(self.parent)-{'SYNTHESIS','VTM_NO_DPI'}|{'VEN_L1D_HIGH_PAYLOAD_SELECT'})

    def test_exact_extension(self):
        self.assertEqual(freeze.profile(self.parent,self.sim),
                         self.parent[:-3]+['VEN_L1D_HIGH_PAYLOAD_SELECT']+self.parent[-3:])

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
        for i in range(132,153):
            altered=list(self.parent);altered[i],altered[i+1]=altered[i+1],altered[i]
            with self.subTest(i=i),self.assertRaises(freeze.FreezeError):
                freeze.profile(altered,self.sim)

    def test_hardware_projection_unchanged(self):
        fixture=parent_tests.Contracts();fixture.setUp()
        hardware=fixture.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')
        self.assertEqual(freeze.projection(hardware,fixture.sim),hardware)
        with self.assertRaises(freeze.FreezeError):freeze.projection(hardware,fixture.sim+b'// drift\n')

    def test_exact_source_delta(self):
        self.assertEqual(freeze.CHANGES,{'rtl/mem/ven_l1d.sv':
            'd78345f1fc81235d5c4881d2ad645eda89ee5da808f2a4131d5bbdda3e178436'})


if __name__=='__main__':unittest.main()
