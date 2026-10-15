"""Ensure identity adapters retain the original architectural comparisons."""
import inspect
from pathlib import Path
import unittest
import run_decode_bus_checks as runner


class DecodeBusChecks(unittest.TestCase):
    def test_reversible_identity_adapters(self):
        for mode in ('func', 'system'):
            source, text, edits = runner.derive(mode, Path('/model/parent'))
            recovered = text
            for old, new in reversed(edits):
                self.assertEqual(recovered.count(new), 1)
                recovered = recovered.replace(new, old)
            self.assertEqual(recovered, source.read_text())
            self.assertIn(runner.MODEL, text)

    def test_delivery_keeps_exact_parent_replay(self):
        text = runner.adapt_delivery(inspect.getsource(runner.delivery.main))
        self.assertIn('len(rows) == 144', text)
        self.assertIn('arow, brow = rows[i], rows[i+1]', text)
        self.assertIn('assert arow[key] == brow[key]', text)
        self.assertIn("'trace_sha256'", text)
        self.assertIn("faults == ['7', '7', '16', '7', '16']", text)
        self.assertIn('receipt[\'native_exit\'] == 133', text)
        compile(text, '<delivery-adapter>', 'exec')


if __name__ == '__main__':
    unittest.main()
