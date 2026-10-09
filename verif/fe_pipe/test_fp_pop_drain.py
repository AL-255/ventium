#!/usr/bin/env python3
"""Source-recipe guards. Hardware behavior requires the differential tests."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('pop_drain', HERE / 'prepare-fp-pop-drain.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (REPO / 'rtl/core/core_fp_async.svh').read_text()

    def test_exact_scope(self):
        result = mod.transform(self.source)
        self.assertIn("(fp_async_count == 3'd1) && fp_shared_rsp_valid", result)
        # Strip only the guarded alternative: default-off text is equivalent.
        start = result.index('`ifdef VEN_FP_POP_DRAIN')
        end = result.index('`endif', start) + len('`endif')
        off = result[:start] + result[end:]
        self.assertEqual(''.join(off.split()), ''.join(self.source.split()))
        # No change to async allocation/response consumption or hold machinery.
        for anchor in ('  assign fp_async_start =', '  assign fp_async_hold =', '  always_ff'):
            self.assertEqual(result[result.index(anchor):], self.source[self.source.index(anchor):])

    def test_reject_reapplication(self):
        with self.assertRaises(ValueError):
            mod.transform(mod.transform(self.source))

    def test_reject_missing_duplicate_anchor(self):
        anchor = '      ((((u_d.fp_kind == FK_ARITH) || (u_d.fp_kind == FK_ARITH_STI)) &&'
        with self.assertRaises(ValueError):
            mod.transform(self.source.replace(anchor, ''))
        with self.assertRaises(ValueError):
            mod.transform(self.source + self.source)

    def test_private_copy(self):
        with tempfile.TemporaryDirectory(prefix='ventium-pop-drain-test-', dir=os.environ['TMPDIR']) as name:
            root = Path(name)
            source = root / 'source'
            (source / 'rtl/core').mkdir(parents=True)
            (source / 'rtl/core/core_fp_async.svh').write_text(self.source)
            (source / 'retain').write_text('unchanged\n')
            result = mod.prepare(source, root / 'candidate')
            self.assertFalse(result['standard_suite'])
            self.assertIsNone(result['gameplay_ipc'])
            self.assertEqual((source / 'rtl/core/core_fp_async.svh').read_text(), self.source)
            with self.assertRaises(ValueError):
                mod.prepare(source, source / 'nested')
            with self.assertRaises(FileExistsError):
                mod.prepare(source, root / 'candidate')


if __name__ == '__main__':
    unittest.main()
