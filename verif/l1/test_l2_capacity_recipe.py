"""Host guards for the frozen-source LRU repair/capacity experiment."""
from pathlib import Path
import unittest

from prepare_l2_capacity import repair_lru_lookup, transform
from run_l2_capacity import tie_unused_primitive_inputs

REPO = Path(__file__).resolve().parents[2]


class RecipeGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = (REPO/'3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v').read_text()
        cls.primitives = (REPO/'ao486-sim/stubs/sim_prims.sv').read_text()

    def test_repair_preserves_geometry_and_ram_count(self):
        fixed = repair_lru_lookup(self.original)
        self.assertIn('localparam LINES         = 128;', fixed)
        self.assertNotIn('CACHE_SETS', fixed)
        for token in ('altdpram #(', 'altsyncram #(', 'localparam LINESIZE      = 8;',
                      'localparam ASSOCIATIVITY = 4;'):
            self.assertEqual(fixed.count(token), self.original.count(token))

    def test_registered_write_set(self):
        fixed = repair_lru_lookup(self.original)
        self.assertEqual(fixed.count('LRU_wraddr <= LRU_addr;'), 1)
        self.assertEqual(fixed.count('LRU_wraddr      <= update_tag_addr;'), 1)
        self.assertIn('.rdaddress(LRU_addr)', fixed)
        self.assertIn('.wraddress(LRU_wraddr)', fixed)
        self.assertNotIn('.wraddress(LRU_addr)', fixed)

    def test_all_rank_consumers_use_pending_write_forwarding(self):
        fixed = repair_lru_lookup(self.original)
        self.assertEqual(fixed.count('LRU_out[i]'), 1)  # primitive output only
        self.assertIn('.q(LRU_out[i])', fixed)
        self.assertIn('LRU_we && (LRU_wraddr == LRU_addr)', fixed)
        self.assertIn('LRU_write_through ? LRU_in[lru_rank_way] : LRU_out[lru_rank_way]', fixed)

    def test_double_application_rejected(self):
        with self.assertRaises(ValueError): repair_lru_lookup(repair_lru_lookup(self.original))

    def test_missing_admission_rejected(self):
        with self.assertRaises(ValueError):
            repair_lru_lookup(self.original.replace('read_addr     <= CPU_ADDR', 'read_addr <= CPU_ADDR'))

    def test_ambiguous_admission_rejected(self):
        with self.assertRaises(ValueError): repair_lru_lookup(self.original+self.original)

    def test_geometry_is_independent_experiment(self):
        larger = transform(self.original)
        self.assertIn('parameter CACHE_SETS = 128', larger)
        self.assertNotIn('LRU_wraddr', larger)
        with self.assertRaises(ValueError): transform(larger)

    def test_unsafe_variants_are_distinct(self):
        read_only = repair_lru_lookup(self.original, write_owner=False)
        no_forward = repair_lru_lookup(self.original, forward=False)
        self.assertNotIn('LRU_wraddr', read_only)
        self.assertIn('LRU_wraddr', no_forward)
        self.assertNotIn('LRU_write_through', no_forward)

    def test_optional_pin_binding_refuses_consumed_inputs(self):
        bound = tie_unused_primitive_inputs(self.original, self.primitives)
        self.assertEqual(bound.count(".inclocken(1'b1)"), 3)
        changed = self.primitives.replace('module altdpram #(', 'module altdpram #(\n// rden now consumed')
        with self.assertRaises(AssertionError): tie_unused_primitive_inputs(self.original, changed)


if __name__ == '__main__': unittest.main()
