#!/usr/bin/env python3
"""Recipe guards only; not a substitute for cold full-core differential tests."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('short_window', HERE / 'prepare-fp-short-window.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def disabled(text):
    """Remove only this experiment's guarded blocks, preserving other defines."""
    out, depth = [], 0
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
            out.append(line)
    assert depth == 0
    return ''.join(out)


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (REPO / 'rtl/core/core.sv').read_text()

    def test_default_off(self):
        # Empty observational `ifndef SYNTHESIS survives; it has no RTL.
        after = disabled(mod.transform(self.source)).replace('`ifndef SYNTHESIS\n`endif\n', '')
        self.assertEqual(''.join(after.split()), ''.join(self.source.split()))

    def test_exact_scope(self):
        result = mod.transform(self.source)
        self.assertEqual(result.count('|| pipe_fp_short_window_ok'), 1)
        self.assertIn('&& !d_unknown && d_is_x87', result)
        self.assertIn('&& ic_buffered(flin + {28\'d0,d_len} - 32\'d1)', result)
        # This changes capture, not execution or reference decoder semantics.
        anchor = '      if (pipe_sdispatch_shape_ok) begin'
        self.assertEqual(result[result.index(anchor):], self.source[self.source.index(anchor):])

    def test_reject_reapplication(self):
        with self.assertRaises(ValueError):
            mod.transform(mod.transform(self.source))

    def test_reject_missing_duplicate(self):
        with self.assertRaises(ValueError):
            mod.transform(self.source.replace('  task automatic pipe_capture_slow_window;', ''))
        with self.assertRaises(ValueError):
            mod.transform(self.source + self.source)

    def test_private_copy(self):
        with tempfile.TemporaryDirectory(prefix='ventium-fp-short-test-', dir=os.environ['TMPDIR']) as name:
            root = Path(name)
            source = root / 'source'
            (source / 'rtl/core').mkdir(parents=True)
            (source / 'rtl/core/core.sv').write_text(self.source)
            (source / 'retain').write_text('unchanged\n')
            result = mod.prepare(source, root / 'candidate')
            self.assertFalse(result['standard_suite'])
            self.assertIsNone(result['gameplay_ipc'])
            self.assertEqual((source / 'rtl/core/core.sv').read_text(), self.source)
            with self.assertRaises(ValueError):
                mod.prepare(source, source / 'nested')
            with self.assertRaises(FileExistsError):
                mod.prepare(source, root / 'candidate')


if __name__ == '__main__':
    unittest.main()
