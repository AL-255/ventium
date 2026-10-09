#!/usr/bin/env python3
"""Source-boundary guards; RTL tests must prove actual ownership and data."""
import os
from pathlib import Path
import tempfile
import unittest
from prepare_data_under_ifill import ANCHOR, FLAG, REPLACEMENT, prepare, transform


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (Path(__file__).resolve().parents[2] / 'rtl/mem/ven_l1d.sv').read_text()

    def test_scope(self):
        text = transform(self.source)
        self.assertEqual(text.replace(REPLACEMENT, ANCHOR), self.source)
        self.assertEqual(text.count(FLAG), 1)
        self.assertEqual(text.count('always_ff'), self.source.count('always_ff'))
        for guard in ('!bypass_q && !xline', '&& !snoop_inv_valid',
                      '&& !(BYPASS_RD_EN && !cacheable)'):
            self.assertEqual(text.count(guard), self.source.count(guard))

    def test_drift(self):
        for text in (self.source + self.source, self.source.replace(ANCHOR, ''),
                     transform(self.source)):
            with self.assertRaises(ValueError):
                transform(text)

    def test_private(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'], prefix='ventium-ifill-test-') as tmp:
            source = Path(tmp) / 'source'
            (source / 'rtl/mem').mkdir(parents=True)
            (source / 'rtl/mem/ven_l1d.sv').write_text(self.source)
            (source / 'preserved').write_text('unchanged\n')
            result = prepare(source, Path(tmp) / 'candidate')
            self.assertFalse(result['production_selected'])
            self.assertIsNone(result['gameplay_ipc'])
            with self.assertRaises(ValueError):
                prepare(source, source / 'nested')
            with self.assertRaises(FileExistsError):
                prepare(source, Path(tmp) / 'candidate')


if __name__ == '__main__':
    unittest.main()
