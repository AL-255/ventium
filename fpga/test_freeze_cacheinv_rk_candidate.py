"""No profile substitution, hardware topology change or unreviewed payload."""
import unittest
import freeze_cacheinv_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class CacheinvProfile(unittest.TestCase):
    def setUp(self):
        self.parent = [f'BASE_{i}' for i in range(132)]+['VEN_SFETCH16_DEMAND']+list(
            freeze.PARENT_EXTRA)+['VEN_IC_RESIDENCY_SPAN','VEN_IC_PREFIX_SPAN',
                                 'SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        self.sim = sorted(set(self.parent)-{'SYNTHESIS','VTM_NO_DPI'} | {'VEN_CACHEINV_LOCAL'})

    def test_exact_extension(self):
        self.assertEqual(freeze.profile(self.parent,self.sim),
                         self.parent[:-3]+['VEN_CACHEINV_LOCAL']+self.parent[-3:])

    def test_missing_or_replaced_features_refused(self):
        for name in self.sim:
            for replacement in ([],['VEN_UNKNOWN'],['VEN_UOPCACHE'],['VEN_CACHE_HALF']):
                with self.subTest(name=name),self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.parent,[x for x in self.sim if x!=name]+replacement)

    def test_duplicate_flags_refused(self):
        for parent,sim in ((self.parent+self.parent[:1],self.sim),
                           (self.parent,self.sim+self.sim[:1]),
                           (self.parent,self.sim[1:]+self.sim[1:2])):
            with self.assertRaises(freeze.FreezeError):
                freeze.profile(parent,sim)

    def test_parent_order_drift_refused(self):
        for i in range(132,147):
            altered=list(self.parent)
            altered[i],altered[i+1]=altered[i+1],altered[i]
            with self.subTest(i=i),self.assertRaises(freeze.FreezeError):
                freeze.profile(altered,self.sim)

    def test_hardware_projection_unchanged(self):
        fixture=parent_tests.Contracts();fixture.setUp()
        hardware=fixture.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')
        self.assertEqual(freeze.projection(hardware,fixture.sim),hardware)
        with self.assertRaises(freeze.FreezeError):
            freeze.projection(hardware,fixture.sim+b'// drift\n')

    def test_only_reviewed_core_and_fragment(self):
        self.assertEqual(freeze.CHANGES,{'rtl/core/core.sv':
            '4188d89cef21597aedd3ac5ee8911c71fb79b7fa6dad1efa00bdd305cbb34b7e'})
        self.assertEqual(freeze.NEW_HEADER,'ventium/rtl/core/core_cacheinv_local.svh')
        self.assertEqual(freeze.NEW_HEADER_SHA,
                         'bc044d5354b15724fd602bb37f23a6cd940b1bc04a911d39f4e5f1b614156a21')


if __name__=='__main__':
    unittest.main()
