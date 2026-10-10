#!/usr/bin/env python3
"""Host-only sharing-profile guards; no hardware or simulation acceptance."""
import unittest

import freeze_ic_buffered_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class BufferedProfile(unittest.TestCase):
    def setUp(self):
        self.parent=[f'BASE_{i}' for i in range(132)]+['VEN_SFETCH16_DEMAND']+list(
            freeze.PARENT_EXTRA)+['SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        self.sim=sorted((set(self.parent)|set(freeze.EXTRA))-{'SYNTHESIS','VTM_NO_DPI'})

    def test_exact(self):
        actual=freeze.profile(self.parent,self.sim)
        self.assertEqual(actual,self.parent[:-3]+list(freeze.EXTRA)+self.parent[-3:])
        self.assertEqual(len(actual),147)

    def test_missing_substituted_or_duplicate_flag(self):
        for replacement in ([],['VEN_UNKNOWN'],['VEN_UOPCACHE'],['VEN_CACHE_HALF'],
                            [self.sim[0]],list(freeze.EXTRA)*2):
            with self.subTest(replacement=replacement),self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent,[x for x in self.sim if x not in freeze.EXTRA]+replacement)

    def test_every_parent_performance_feature_retained(self):
        for name in freeze.PARENT_EXTRA:
            with self.subTest(name=name),self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent,[x for x in self.sim if x!=name]+['VEN_UNKNOWN'])

    def test_parent_order_and_duplicates(self):
        for parent in (self.parent[:-1],self.parent[:-3]+list(reversed(self.parent[-3:])),
                       self.parent[:133]+list(reversed(self.parent[133:143]))+self.parent[143:],
                       list(freeze.EXTRA)+self.parent[1:]):
            with self.subTest(parent=parent),self.assertRaises(freeze.FreezeError):
                freeze.profile(parent,self.sim)

    def test_no_rtl_alias_admission(self):
        self.assertEqual(len(freeze.SCRIPT_ALIASES),17)
        self.assertEqual(len(set(freeze.SCRIPT_ALIASES)),17)
        self.assertTrue(all(p.endswith('/build.py') or p.endswith('/run_matrix.py')
                            for p in freeze.SCRIPT_ALIASES))

    def test_hardware_wrapper_unchanged(self):
        f=parent_tests.Contracts();f.setUp()
        hardware=f.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')
        self.assertEqual(freeze.projection(hardware,f.sim),hardware)
        with self.assertRaises(freeze.FreezeError):
            freeze.projection(hardware,f.sim+b'// unexpected edit\n')


if __name__=='__main__':unittest.main()
