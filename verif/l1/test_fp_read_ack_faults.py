"""Verify the fault matrix does not silently substitute slow-mode acceptance."""
import unittest
from pathlib import Path
from run_fp_read_ack_faults import cases, compare_command, environment


class FaultMatrix(unittest.TestCase):
    def test_matrix(self):
        rows = cases()
        self.assertEqual(len(rows), 16)
        self.assertEqual(len({tuple(sorted(row.items())) for row in rows}), 16)
        self.assertEqual(sum(row['nm'] != 0 for row in rows), 6)
        self.assertEqual(sum(row['pending'] for row in rows), 5)
        self.assertEqual(sum(row['segment'] != 0 for row in rows), 4)
        for row in rows:
            self.assertFalse(row['nm'] and (row['pending'] or row['segment']))
            self.assertFalse(row['kind'] and row['segment'])

    def test_same_enabled_profile(self):
        for row in cases():
            control = environment(row, Path('/control'), Path('/a'))
            candidate = environment(row, Path('/candidate'), Path('/b'))
            for key in control.keys() - {'TB_BIN', 'OUTDIR'}:
                self.assertEqual(control[key], candidate[key])
            self.assertEqual(control['FP_MEM_ADMIT'], '1')
            self.assertEqual(control['FP_LOAD_COMMAND'], '1')

    def test_complete_unmasked_compare(self):
        command = compare_command(Path('/qemu.vtrace'), Path('/cycle-func.vtrace'))
        self.assertEqual(command[-5:], ['--mode', 'func', '--all',
                         '/qemu.vtrace', '/cycle-func.vtrace'])
        self.assertNotIn('--eflags-mask', command)


if __name__ == '__main__':
    unittest.main()
