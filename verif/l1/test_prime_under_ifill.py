#!/usr/bin/env python3
"""Reversible source guards, independent of a mutable private source path."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from prepare_prime_under_ifill import ANCHOR, FLAG, REPLACEMENT, prepare, transform
from prepare_data_under_ifill import transform as data_transform

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prime_parent', REPO/'verif/fe_pipe/prepare-prime-under-fill.py')
parent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parent)

class Guards(unittest.TestCase):
    def setUp(self):
        self.source = data_transform(parent.transform((REPO/'rtl/mem/ven_l1d.sv').read_text()))

    def test_reversible(self):
        result = transform(self.source)
        self.assertEqual(result.replace(REPLACEMENT, ANCHOR), self.source)
        self.assertEqual(result.count(FLAG), 1)
        self.assertIn('code_fill_q ? !code_access', result)

    def test_drift(self):
        for text in (self.source+self.source, self.source.replace(ANCHOR, ''),
                     transform(self.source), self.source.replace('VEN_L1D_DATA_UNDER_IFILL', 'OTHER')):
            with self.assertRaises(ValueError): transform(text)

    def test_private_copy(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'], prefix='ventium-prime-ifill-test-') as name:
            source = Path(name)/'source'
            (source/'rtl/mem').mkdir(parents=True)
            (source/'rtl/mem/ven_l1d.sv').write_text(self.source)
            (source/'retained').write_text('unchanged\n')
            result = prepare(source, Path(name)/'candidate')
            self.assertFalse(result['production_selected'])
            self.assertIsNone(result['gameplay_ipc'])
            with self.assertRaises(ValueError): prepare(source, source/'nested')
            with self.assertRaises(FileExistsError): prepare(source, Path(name)/'candidate')

if __name__ == '__main__': unittest.main()
