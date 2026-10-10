"""Narrow source/profile guards for completing the shared retirement gather."""
import unittest
import freeze_ic_prefix_capture_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class CaptureProfile(unittest.TestCase):
    def setUp(self):
        self.parent = [f'BASE_{i}' for i in range(132)]+['VEN_SFETCH16_DEMAND']+list(
            freeze.PARENT_EXTRA)+['VEN_IC_RESIDENCY_SPAN','VEN_IC_PREFIX_SPAN',
                                 'SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        self.sim = sorted(set(self.parent)-{'SYNTHESIS','VTM_NO_DPI'})

    def test_exact_no_feature_added_or_removed(self):
        self.assertEqual(freeze.profile(self.parent,self.sim),self.parent)
        self.assertEqual(len(self.parent),148)
        self.assertEqual(len(self.sim),146)

    def test_every_performance_flag_required(self):
        for name in self.parent[132:145]:
            for replacement in ([],['VEN_UNKNOWN'],['VEN_UOPCACHE'],['VEN_CACHE_HALF']):
                with self.subTest(name=name,replacement=replacement),self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.parent,[x for x in self.sim if x!=name]+replacement)

    def test_duplicate_native_and_parent_flags_rejected(self):
        for parent,sim in ((self.parent+self.parent[:1],self.sim),
                           (self.parent,self.sim+self.sim[:1]),
                           (self.parent,self.sim[1:]+self.sim[1:2])):
            with self.subTest(parent=parent,sim=sim),self.assertRaises(freeze.FreezeError):
                freeze.profile(parent,sim)

    def test_all_bundle_order_changes_rejected(self):
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

    def test_only_reviewed_retire_include_can_change(self):
        self.assertEqual(freeze.CHANGES,{'rtl/core/core_int_retire.svh':
            '76da2937ce317ae31da831d4376c82b0c33fe3b0ffd9d4fbfbf68d05458dfe7f'})
        self.assertEqual(len(freeze.SCRIPT_ALIASES),len(set(freeze.SCRIPT_ALIASES)))
        self.assertTrue(all(p.endswith('.py') for p in freeze.SCRIPT_ALIASES))


if __name__=='__main__':unittest.main()
