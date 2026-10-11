"""Source-scope checks; the real-ISA differential is the behavioral authority."""
import os
from pathlib import Path
import unittest

import prepare_descriptor_read_extent as patch
import run_descriptor_read_extent as repro


class DescriptorExtent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['DESCRIPTOR_PARENT'])
        cls.core = (parent/'core.sv').read_text()
        cls.bus = (parent/'core_bus_driver.svh').read_text()

    def test_exact_two_arm_changes(self):
        core, bus = patch.transform(self.core, self.bus)
        self.assertEqual(core.replace(patch.CORE_NEW, patch.CORE_OLD), self.core)
        self.assertEqual(bus.replace(patch.BUS_NEW, patch.BUS_OLD), self.bus)
        self.assertIn("cur_size = seg_step ? 4'd2 : 4'd4;", patch.CORE_NEW)
        self.assertIn("bd_wstrb = seg_step ? 4'b0011 : 4'b1111;", patch.BUS_NEW)

    def test_drift_and_reapplication_rejected(self):
        for core, bus in ((self.core+'\n', self.bus), (self.core, self.bus+'\n'),
                          patch.transform(self.core, self.bus)):
            with self.assertRaises(ValueError):
                patch.transform(core, bus)

    def test_fixture_boundary_and_original_handlers(self):
        original = (repro.REPO/'verif/sys/tests/pxfrag/pxfrag.S').read_text()
        handler = original[original.index('/* #PF handler:'):]
        for op in ('lgdt', 'lidt'):
            for address in (0x2ff8, 0x2ff9, 0x2ffa):
                for cd in (0, 1):
                    fixture = repro.fixture(original, address, op, cd)
                    self.assertIn(f'    {op} 0x{address:08x}\n', fixture)
                    self.assertIn(f'    movl $0x00400000, 0x{address+2:08x}', fixture)
                    self.assertTrue(fixture.endswith(handler))
                    self.assertLessEqual(address+6, 0x3000)
        with self.assertRaises(AssertionError):
            repro.fixture(original+'\n', 0x2ffa, 'lgdt', 1)


if __name__ == '__main__':
    unittest.main()
