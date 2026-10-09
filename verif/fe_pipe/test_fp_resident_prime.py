#!/usr/bin/env python3
"""Transformation guards, not RTL or performance acceptance tests."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prime', HERE/'prepare-fp-resident-prime.py')
prime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prime)

ANCHOR = '''  assign mc_fp_self_prime = pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM &&
                           !mc_valid_q && !pipe_mem_active_q;'''


class Guards(unittest.TestCase):
    def test_restricts_operand_without_changing_owner_checks(self):
        before = 'prefix\n'+ANCHOR+'\nsuffix\n'
        after = prime.restrict_arith32(before)
        self.assertTrue(after.startswith('prefix\n'))
        self.assertTrue(after.endswith('\nsuffix\n'))
        self.assertIn("pipe_u_eff.fp_role == 3'd0", after)
        self.assertIn('!pipe_u_eff.fp_sti[0]', after)
        self.assertIn('!pipe_u_eff.fp_aluop[1]', after)
        self.assertIn('!mc_valid_q && !pipe_mem_active_q;', after)
        self.assertIn('pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM', after)

    def test_rejects_missing_and_duplicate_anchors(self):
        for text in ('', ANCHOR+'\n'+ANCHOR):
            with self.assertRaises(ValueError):
                prime.restrict_arith32(text)

    def test_rejects_reapplication(self):
        with self.assertRaises(ValueError):
            prime.restrict_arith32(prime.restrict_arith32(ANCHOR))

    def test_requires_forwarding_source_before_copy(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            root = Path(directory)
            source = root/'source'
            (source/'fp_shared').mkdir(parents=True)
            (source/'fp_shared/ven_fp_top.sv').write_text('// older top\n')
            with self.assertRaisesRegex(ValueError, 'requires the memory-forwarding'):
                prime.prepare(source, root/'output', arith32=True)
            self.assertFalse((root/'output').exists())


if __name__ == '__main__':
    unittest.main()
