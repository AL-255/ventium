"""Fixture construction tests; the real model/QEMU evidence is separate."""
from pathlib import Path
import unittest

import run_fragment_abort_replacement as probe


class FragmentFixtures(unittest.TestCase):
    def setUp(self):
        self.source = (probe.REPO/'verif/sys/tests/pxfrag/pxfrag.S').read_text()

    def test_all_twelve_distinct(self):
        variants = {probe.fixture(self.source, first, warm, cd)
                    for first in (1, 2, 3) for warm in (False, True) for cd in (False, True)}
        self.assertEqual(len(variants), 12)

    def test_gate_and_idtr_consistency(self):
        for first in (1, 2, 3):
            text = probe.fixture(self.source, first, False, False)
            gate = 0x9000-first
            self.assertIn(f'movl    $0x{gate:08X}, %edi', text)
            self.assertIn(f'movl    $0x{gate-8:08X}, %edi', text)
            self.assertIn(f'movl    $0x{gate-14*8:08X}, 0x0492', text)
            self.assertEqual(text.count(probe.ANCHOR), 1)

    def test_cache_and_warm_options_are_guest_instructions(self):
        cold = probe.fixture(self.source, 3, False, False)
        warm = probe.fixture(self.source, 3, True, True)
        self.assertIn('andl    $0x9FFFFFFF, %eax', cold)
        self.assertNotIn('orl     $0x40000000, %eax', cold)
        self.assertIn('orl     $0x40000000, %eax', warm)
        self.assertEqual(warm.count('movl    0x00008FFC, %eax'), 2)
        self.assertNotIn('movl    0x00008FFC, %eax', cold)

    def test_source_drift_and_bad_split_rejected(self):
        for first in (0, 4, 8):
            with self.assertRaises(ValueError):
                probe.fixture(self.source, first, False, False)
        with self.assertRaises(ValueError):
            probe.fixture(self.source+'\n', 3, True, True)


if __name__ == '__main__':
    unittest.main()
