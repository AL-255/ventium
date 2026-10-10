#!/usr/bin/env python3
"""Source-recipe checks only; these do not qualify RTL or shorten RET timing."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('ret_short', HERE/'prepare-ret-short-window.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def disabled(text):
    output, depth = [], 0
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
            output.append(line)
    assert depth == 0
    return ''.join(output)


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (REPO/'rtl/core/core.sv').read_text()

    def test_default_off_byte_exact(self):
        self.assertEqual(disabled(mod.transform(self.source)), self.source)

    def test_execution_unchanged(self):
        result = mod.transform(self.source)
        anchor = '      if (pipe_sdispatch_shape_ok) begin'
        self.assertEqual(result[result.index(anchor):], self.source[self.source.index(anchor):])
        self.assertEqual(result.count('|| pipe_ret_short_window_ok'), 1)
        self.assertIn("(d_ct == CT_RETN) && (d_len == 4'd1)", result)
        self.assertIn("(d_ct == CT_RETN_IMM) && (d_len == 4'd3)", result)
        self.assertNotIn('state <= S_EXEC', mod.PREDICATE)
        self.assertNotIn('mem_ack', mod.PREDICATE)

    def test_all_existing_instructions_preserved(self):
        # Every original byte remains after removing only the new opt-in code.
        result = mod.transform(self.source)
        self.assertEqual(result.count('capture_reference_decode(eip);'),
                         self.source.count('capture_reference_decode(eip);'))
        self.assertIn('&& exec_issue_ok && !icsnp_v1 && !icsnp_v2', result)
        self.assertIn("&& ic_buffered(flin + {28'd0,d_len} - 32'd1)", result)

    def test_reject_reapply_and_drift(self):
        with self.assertRaises(ValueError):
            mod.transform(mod.transform(self.source))
        for text in [self.source+self.source,
                     self.source.replace('task automatic pipe_capture_slow_window;', ''),
                     self.source.replace("          ibuf[i] <= 8'd0;", '')]:
            with self.assertRaises(ValueError):
                mod.transform(text)

    def test_private_output_never_overwrites(self):
        with tempfile.TemporaryDirectory(prefix='ventium-ret-short-test-', dir=os.environ['TMPDIR']) as d:
            source = Path(d)/'core.sv'
            output = Path(d)/'candidate.sv'
            source.write_text(self.source)
            record = mod.prepare(source, output)
            self.assertFalse(record['production_changed'])
            self.assertEqual(source.read_text(), self.source)
            self.assertEqual(disabled(output.read_text()), self.source)
            with self.assertRaises(FileExistsError):
                mod.prepare(source, output)
            with self.assertRaises(ValueError):
                mod.prepare(source, source)


if __name__ == '__main__':
    unittest.main()
