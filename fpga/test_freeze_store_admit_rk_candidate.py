#!/usr/bin/env python3
"""Host-only exact-profile guards; no Vivado, RTL model or board is run."""
import unittest

import freeze_store_admit_rk_candidate as freeze
import test_freeze_performance_rk_candidate as parent_tests


class CombinedProfile(unittest.TestCase):
    def setUp(self):
        self.parent = [f'BASE_{i}' for i in range(132)] + [
            'VEN_SFETCH16_DEMAND', 'SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM']
        self.sim = sorted((set(self.parent) | set(freeze.EXTRA)) - {'SYNTHESIS','VTM_NO_DPI'})

    def test_exact(self):
        actual = freeze.profile(self.parent, self.sim)
        self.assertEqual(actual, self.parent[:-3]+list(freeze.EXTRA)+self.parent[-3:])
        self.assertEqual(len(actual), 146)

    def test_each_missing_or_substituted_feature(self):
        for name in freeze.EXTRA:
            for replacement in ([], ['VEN_UNKNOWN'], ['VEN_CACHE_HALF'], ['VEN_UOPCACHE']):
                with self.subTest(name=name,replacement=replacement), self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.parent,[x for x in self.sim if x != name]+replacement)

    def test_duplicate_or_extra(self):
        for sim in (self.sim+[self.sim[0]], self.sim[:-1]+[self.sim[0]], self.sim+['VEN_EXTRA']):
            with self.subTest(sim=sim), self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent, sim)

    def test_parent_drift(self):
        for parent in (self.parent[:-1], self.parent[:-4]+list(reversed(self.parent[-4:])),
                       [freeze.EXTRA[0]]+self.parent[1:]):
            with self.subTest(parent=parent), self.assertRaises(freeze.FreezeError):
                freeze.profile(parent,self.sim)

    def test_hardware_unchanged(self):
        fixture = parent_tests.Contracts(); fixture.setUp()
        parent = fixture.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')
        self.assertEqual(freeze.projection(parent,fixture.sim), parent)
        for bad in (fixture.sim.replace(b'BOARD_WRITE_SLOTS=16',b'BOARD_WRITE_SLOTS=8'),
                    fixture.sim.replace(b'CACHE_SETS(1024)',b'CACHE_SETS(128)'),
                    fixture.sim+b'// unexpected edit\n'):
            with self.subTest(bad=bad), self.assertRaises(freeze.FreezeError):
                freeze.projection(parent,bad)


if __name__ == '__main__': unittest.main()
