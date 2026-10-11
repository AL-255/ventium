from pathlib import Path
import unittest
from prepare_fp_fragment_faults import transform


class FragmentFixture(unittest.TestCase):
    def setUp(self):
        self.source = (Path(__file__).resolve().parents[2] /
                       'verif/sys/tests/prepsfetch/prepsfetch.S').read_text()

    def test_all_three_offsets(self):
        for delta in (1, 2, 3):
            got = transform(self.source, delta)
            for mnemonic in ('fldl', 'fildll', 'faddl'):
                self.assertIn('    %s 0x%08x' % (mnemonic, 0x400ffc+delta), got)
            self.assertIn('    movl $0x%08x, %%ebp' % (0x3f0ffc+delta), got)
            self.assertIn('    cmpl $0x00401000, %eax\n', got)
            self.assertEqual(len(got), len(self.source))

    def test_reject_invalid_or_mutated_source(self):
        for delta in (0, 4, True, '1'):
            with self.assertRaises(ValueError):
                transform(self.source, delta)
        with self.assertRaises(ValueError):
            transform(self.source + '\n', 1)
        with self.assertRaises(ValueError):
            transform(transform(self.source, 1), 1)

    def test_other_tests_and_handler_unchanged(self):
        for delta in (1, 2, 3):
            got = transform(self.source, delta)
            self.assertEqual(got.split('fp_source_handler:\n')[1],
                             self.source.split('fp_source_handler:\n')[1])
            self.assertEqual(got[:got.index('    movl $0, 0x2070')],
                             self.source[:self.source.index('    movl $0, 0x2070')])

    def test_complete_fault_accounting(self):
        from collections import Counter
        from run_fp_read_ack_fragments import expected_faults, check_faultlog
        for nm in (0, 4, 8):
            expected = expected_faults(dict(nm=nm))
            self.assertEqual(sum(expected.values()), 5 if nm else 4)
            check_faultlog.check_counts(Counter(expected), expected)
            for pair in expected:
                broken = Counter(expected)
                broken[pair] -= 1
                with self.assertRaises(ValueError):
                    check_faultlog.check_counts(broken, expected)


if __name__ == '__main__':
    unittest.main()
