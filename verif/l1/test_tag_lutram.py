#!/usr/bin/env python3
"""Scope guards, not a substitute for the cold/warm-reset RTL checks."""
import os
from pathlib import Path
import tempfile
import unittest
from prepare_tag_lutram import ACCESS, DECL, FLAG, RESET, prepare, select_feature, transform


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (Path(__file__).resolve().parents[2] / 'rtl/mem/ven_l1d.sv').read_text()

    def test_default_off_exact(self):
        changed = transform(self.source)
        disabled = select_feature(changed, False)
        self.assertEqual(disabled, self.source)

    def test_enabled_scope(self):
        changed = transform(self.source)
        enabled = select_feature(changed, True)
        self.assertNotIn(RESET, enabled)
        self.assertIn('dc_tag [L1_SETS*2]', enabled)
        self.assertEqual(enabled.count('dc_tag[{'), 11)
        self.assertFalse(ACCESS.search(enabled))
        self.assertEqual(enabled.count('always_ff'), self.source.count('always_ff'))
        self.assertIn("dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;", enabled)
        self.assertIn('dc_tag[{fset,fway}]<=ftag;', enabled)

    def test_lookup_drift_rejected(self):
        with self.assertRaises(ValueError):
            transform(self.source.replace('dc_tag[set_c][0]', 'dc_tag[other_set][0]'))

    def test_index_bijection(self):
        addresses = {(setno << 1) | way for setno in range(128) for way in range(2)}
        self.assertEqual(addresses, set(range(256)))
        for index in addresses:
            self.assertEqual(((index >> 1) << 1) | (index & 1), index)

    def test_drift_rejected(self):
        for text in (self.source + self.source, self.source.replace(DECL, ''),
                     self.source.replace(RESET, ''), transform(self.source)):
            with self.assertRaises(ValueError):
                transform(text)

    def test_private_copy(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'], prefix='ventium-tag-test-') as name:
            source = Path(name) / 'source'
            (source / 'rtl/mem').mkdir(parents=True)
            (source / 'rtl/mem/ven_l1d.sv').write_text(self.source)
            (source / 'retained').write_text('unchanged\n')
            result = prepare(source, Path(name) / 'candidate')
            self.assertFalse(result['production_selected'])
            self.assertIsNone(result['gameplay_ipc'])
            with self.assertRaises(ValueError):
                prepare(source, source / 'nested')
            with self.assertRaises(FileExistsError):
                prepare(source, Path(name) / 'candidate')


if __name__ == '__main__':
    unittest.main()
