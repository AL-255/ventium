#!/usr/bin/env python3
"""Host contracts for reference-only arithmetic-profile isolation."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('prepare_trans_oracle', HERE/'prepare-trans-oracle.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


class OracleTests(unittest.TestCase):
    def setUp(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        self.scratch = tempfile.TemporaryDirectory(prefix='ventium-trans-oracle-host.', dir=scratch)
        self.addCleanup(self.scratch.cleanup)
        self.out = Path(self.scratch.name)/'oracle'
        self.fixture = REPO/'fp_shared/tb/tb_ven_fp_trans.sv'

    def test_only_names_and_macro_envelope_change_reference(self):
        files = oracle.prepare(REPO, self.fixture, self.out)
        old = (REPO/'rtl/fpu/fpu_x87_pkg.sv').read_text()
        body = old.replace('package fpu_x87_pkg;', 'package shared_fp_reference_pkg;')
        body = body.replace('endpackage : fpu_x87_pkg', 'endpackage : shared_fp_reference_pkg')
        package = files[0].read_text()
        self.assertIn(body, package)
        self.assertEqual(package.count('`undef VEN_SRT_ITER'), 1)
        self.assertEqual(package.count('`define VEN_SRT_ITER'), 1)
        self.assertLess(package.index('`undef VEN_SRT_ITER'), package.index(body))
        self.assertGreater(package.index('`define VEN_SRT_ITER'), package.index(body)+len(body))
        reference = (REPO/'rtl/fpu/fpu_fpatan.sv').read_text()
        reference = reference.replace('module fpu_fpatan\n', 'module shared_fp_reference_atan\n')
        reference = reference.replace('import fpu_x87_pkg::*;', 'import shared_fp_reference_pkg::*;')
        self.assertEqual(files[1].read_text(), reference)
        self.assertIn('hardware_ratio !== 83\'d0', files[2].read_text())
        self.assertIn('FP oracle divider is stubbed or incorrect', files[2].read_text())

    def test_existing_output_is_never_overwritten(self):
        oracle.prepare(REPO, self.fixture, self.out)
        before = {p.name: p.read_bytes() for p in self.out.iterdir()}
        with self.assertRaises(FileExistsError):
            oracle.prepare(REPO, self.fixture, self.out)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.out.iterdir()})

    def test_missing_or_ambiguous_anchor_fails_closed(self):
        for text in ('missing', 'twice twice'):
            with self.assertRaises(ValueError):
                oracle.replace_once(text, 'twice', 'new')


if __name__ == '__main__':
    unittest.main()
