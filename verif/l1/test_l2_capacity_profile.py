from pathlib import Path
import unittest

from prepare_l2_capacity import repair_lru_lookup, transform
from prepare_l2_capacity_profile import capacity_profile

REPO=Path(__file__).resolve().parents[2]


class CapacityProfile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original=(REPO/'3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v').read_text()
        cls.cache=repair_lru_lookup(cls.original)
        cls.system=(REPO/'3rd-party/ao486_MiSTer/rtl/system.v').read_bytes().decode()

    def test_geometries_change_only_instance_and_exact_recipe(self):
        for sets in (128,256,512,1024):
            cache,system=capacity_profile(self.cache,self.system,sets)
            self.assertEqual(cache,transform(self.cache))
            self.assertEqual(system.replace(f'l2_cache #(.CACHE_SETS({sets})) cache','l2_cache cache'),self.system)
            self.assertEqual(system.count('\r\n'),self.system.count('\r\n'))

    def test_bad_geometry(self):
        for sets in (0,64,129,2048):
            with self.assertRaises(ValueError):capacity_profile(self.cache,self.system,sets)

    def test_unrepaired_source_rejected(self):
        with self.assertRaises(ValueError):capacity_profile(self.original,self.system,1024)

    def test_missing_forwarding_rejected(self):
        with self.assertRaises(ValueError):capacity_profile(self.cache.replace('LRU_we &&','1\'b0 &&'),self.system,1024)

    def test_ambiguous_instance_rejected(self):
        with self.assertRaises(ValueError):capacity_profile(self.cache,self.system+self.system,1024)

    def test_double_application_rejected(self):
        cache,system=capacity_profile(self.cache,self.system,1024)
        with self.assertRaises(ValueError):capacity_profile(cache,system,1024)


if __name__=='__main__':unittest.main()
