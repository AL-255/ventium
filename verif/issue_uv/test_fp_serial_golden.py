"""Scheduling adaptation contracts; native QEMU/RTL coverage is separate."""
import ast
from pathlib import Path
import unittest
from run_fp_same_profile_serial_golden import adapt, GOLDEN, SERIAL


class SerialGolden(unittest.TestCase):
    def test_only_complete_golden_transaction_is_locked(self):
        source = Path(__file__).with_name('run-fp-payload-ab.py').read_text()
        changed = adapt(source)
        ast.parse(changed)
        self.assertEqual(changed.count(SERIAL), 1)
        self.assertIn('ThreadPoolExecutor(max_workers=args.workers)', changed)
        self.assertEqual(changed.count('with golden_lock:'), 1)
        self.assertEqual(changed.split("        gold = tracefmt.read_trace")[1],
                         source.split("        gold = tracefmt.read_trace")[1])

    def test_missing_golden_start_refused(self):
        source = Path(__file__).with_name('run-fp-payload-ab.py').read_text()
        with self.assertRaises(ValueError):
            adapt(source.replace(GOLDEN, ''))

    def test_reapplication_refused(self):
        source = Path(__file__).with_name('run-fp-payload-ab.py').read_text()
        with self.assertRaises(ValueError):
            adapt(adapt(source))


if __name__ == '__main__':
    unittest.main()
