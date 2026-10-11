import os
from pathlib import Path
import unittest
from prepare_fp_read_ack_split import PARENTS, transform, ack_block, read_ack_block


class Recipe(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ['FP_READ_ACK_PARENT'])

    def test_all_exact_sources(self):
        for name in PARENTS:
            with self.subTest(name=name):
                before = (self.root/name).read_text()
                after = transform(name, before)
                self.assertNotEqual(before, after)
                # The transformation independently reverses every hunk and
                # verifies the original whole-file SHA, not only a marker.
                for drift in (before+'\n', after):
                    with self.assertRaises(ValueError): transform(name, drift)

    def test_original_ack_and_data_block_unchanged(self):
        name = 'rtl/mem/ven_l1d.sv'
        before = (self.root/name).read_text()
        after = transform(name, before)
        self.assertEqual(ack_block(before), ack_block(after))
        old = before[before.index('  // core-side response:'):]
        self.assertEqual(old, after[after.index('  // core-side response:'):])

    def test_read_cofactor_has_no_store_credit_inputs(self):
        name = 'rtl/mem/ven_l1d.sv'
        block = read_ack_block(transform(name, (self.root/name).read_text()))
        for signal in ('m_ack', 'm_pair_ack', 'c_pair_ready', 'c_pair_req'):
            self.assertNotIn(signal, block)
        self.assertIn('c_req && !c_we', block)
        self.assertIn('if (stream_path)', block)

    def test_fault_fragment_and_legacy_controls_retained(self):
        name = 'rtl/core/core.sv'
        result = transform(name, (self.root/name).read_text())
        self.assertIn('assign mem_read_ack = bus_read_ack && !fx_hold_e;', result)
        self.assertIn('assign mem_read_ack = mem_ack;', result)
        self.assertIn('q_f_mem_read && !q_f_mem_write && mem_read_ack && fsm_case_enabled', result)
        for name in ('rtl/ventium_top.sv', 'rtl/mem/ventium_l1_axi.sv'):
            before = (self.root/name).read_text()
            after = transform(name, before)
            # No pre-existing assign (except high-half ACK selection) is removed.
            for line in before.splitlines():
                if 'assign core_mem_ack' in line or 'assign core_ack ' in line:
                    self.assertIn(line, after)


if __name__ == '__main__': unittest.main()
