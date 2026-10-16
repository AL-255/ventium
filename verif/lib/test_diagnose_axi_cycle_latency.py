#!/usr/bin/env python3
"""Host-only rejection tests for the native latency diagnostic."""
import tempfile
from pathlib import Path
import unittest

import diagnose_axi_cycle_latency as driver


class Commands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tb = self.root / 'model'
        self.tb.touch()
        self.receipt = self.root / 'argv'
        self.args = [str(self.tb), '--image', '/input', '--load', '0x8000',
                     '--entry', '0x8000', '--init-esp', '0x4000', '--cycle',
                     '--out', '/output', '--max-insn', '100',
                     '--max-cycles', '80000000', '--l1-axi']

    def decode(self, args, terminated=True):
        self.receipt.write_bytes('\0'.join(args).encode() + (b'\0' if terminated else b''))
        return driver.decode_argv(self.receipt, self.tb)

    def test_exact_uv_axi_command(self):
        self.assertEqual(self.decode(self.args), self.args)
        self.assertEqual(self.decode(self.args + ['--x87']), self.args + ['--x87'])

    def test_debugger_mode_overrides_rejected(self):
        for extra in (['--dbg-step'], ['--dbg-bp', '0x8000'],
                      ['--cycle-func'], ['--no-trace']):
            with self.subTest(extra=extra), self.assertRaises(AssertionError):
                self.decode(self.args + extra)

    def test_incomplete_receipt_rejected(self):
        with self.assertRaises(AssertionError):
            self.decode(self.args, False)

    def test_direct_memory_rejected(self):
        with self.assertRaises(AssertionError):
            self.decode(self.args[:-1])

    def test_duplicate_scalar_rejected(self):
        with self.assertRaises(AssertionError):
            self.decode(self.args + ['--max-insn', '1'])

    def test_different_model_rejected(self):
        other = self.root / 'other'
        other.touch()
        with self.assertRaises(AssertionError):
            self.decode([str(other), *self.args[1:]])


if __name__ == '__main__':
    unittest.main()
