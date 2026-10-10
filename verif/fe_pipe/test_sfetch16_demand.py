#!/usr/bin/env python3
"""Recipe/invariant checks, not a replacement for actual RTL verification."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('sfetch16', HERE/'prepare-sfetch16-demand.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def disabled(text):
    result, depth = [], 0
    for line in text.splitlines(keepends=True):
        directive = line.strip()
        if depth:
            if directive.startswith(('`ifdef ', '`ifndef ')):
                depth += 1
            elif directive == '`endif':
                depth -= 1
        elif directive == '`ifdef ' + mod.FLAG:
            depth = 1
        else:
            result.append(line)
    assert depth == 0
    return ''.join(result)


class Recipe(unittest.TestCase):
    def setUp(self):
        self.source = (REPO/'rtl/core/core.sv').read_text()

    def test_disabled_byte_exact(self):
        self.assertEqual(disabled(mod.transform(self.source)), self.source)

    def test_execution_owners_unchanged(self):
        result = mod.transform(self.source)
        anchor = '  // This tiny authorization cache is independent'
        self.assertEqual(result[result.index(anchor):], self.source[self.source.index(anchor):])
        self.assertIn('(state == S_FETCH) && def16 && !sfetch_boundary', mod.SELECT)
        self.assertNotIn('mem_ack', mod.SELECT)
        self.assertNotIn('state <=', mod.SELECT)

    def test_guard_drift_and_reapply_rejected(self):
        with self.assertRaises(ValueError):
            mod.transform(mod.transform(self.source))
        for anchor in ['  logic sfetch_boundary, sfetch_demand_req;\n',
                       '(sfetch_valid_q < d_fetch_need)',
                       "(def16 && (eip[15:0] > 16'hfff0))"]:
            with self.assertRaises(ValueError):
                mod.transform(self.source.replace(anchor, ''))

    def test_private_output_no_overwrite(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'], prefix='ventium-demand16-test-') as d:
            src, out = Path(d)/'original.sv', Path(d)/'candidate.sv'
            src.write_text(self.source)
            record = mod.prepare(src, out)
            self.assertFalse(record['production_changed'])
            self.assertEqual(src.read_text(), self.source)
            with self.assertRaises(FileExistsError):
                mod.prepare(src, out)
            with self.assertRaises(ValueError):
                mod.prepare(src, src)

    def test_interior_span_subset_all_page_offsets(self):
        # Independent arithmetic property of the new four-byte policy. The
        # actual SV parser and handshake are exercised by the native core test.
        for start in range(4096-15):
            for need in range(1, 17):
                end = start + ((need + 3) // 4) * 4 - 1
                self.assertLessEqual(end, start + 15)
                self.assertLessEqual(end, 4095)


if __name__ == '__main__':
    unittest.main()
