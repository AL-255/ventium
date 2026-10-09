#!/usr/bin/env python3
"""Recipe scope/default-off guards, not hardware correctness proof."""
import difflib
import os
from pathlib import Path
import tempfile
import unittest
from prepare_code_word_reuse import FLAG, prepare, transform


REPO = Path(__file__).resolve().parents[2]


def without_feature(text):
    lines, depth = [], 0
    for line in text.splitlines(keepends=True):
        if not depth and line.strip() == '`ifdef ' + FLAG:
            depth = 1
        elif depth:
            if line.lstrip().startswith(('`ifdef ', '`ifndef ')):
                depth += 1
            elif line.strip() == '`endif':
                depth -= 1
        else:
            lines.append(line)
    if depth:
        raise ValueError('unclosed feature guard')
    return ''.join(lines)


class Guards(unittest.TestCase):
    def setUp(self):
        self.source = (REPO / 'rtl/mem/ven_l1d.sv').read_text()

    def test_default_off_exact(self):
        self.assertEqual(without_feature(transform(self.source)), self.source)

    def test_no_new_clocked_state(self):
        changed = transform(self.source)
        added = '\n'.join(line[2:] for line in difflib.ndiff(
            self.source.splitlines(), changed.splitlines()) if line.startswith('+ '))
        self.assertNotIn('always', added)
        self.assertNotIn('<=', added)
        self.assertIn('fill_forward_code_hit);', changed)
        self.assertIn('!flush_all && !snoop_inv_valid && !early_armed', changed)

    def test_reapply_rejected(self):
        with self.assertRaises(ValueError):
            transform(transform(self.source))

    def test_retained_payload_miter(self):
        source = self.source + '''
  logic [31:0] payload_before_cut;
  // Stand-in for the frozen variant's uniquely anchored reference expression.
                       : early_match ? early_rdata_q
'''
        changed = transform(source)
        self.assertEqual(without_feature(changed), source)
        self.assertIn("32'(code_line_q >> {c_addr[4:0],3'b000})", changed)
        with self.assertRaises(ValueError):
            transform(source.replace('                       : early_match ?', ': early_match ?'))

    def test_missing_and_duplicate_rejected(self):
        with self.assertRaises(ValueError):
            transform(self.source.replace('  assign fill_forward_hit =', '  assign renamed_hit ='))
        with self.assertRaises(ValueError):
            transform(self.source + self.source)

    def test_private_copy(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'], prefix='ventium-code-word-test-') as name:
            source = Path(name)/'source'
            (source/'rtl/mem').mkdir(parents=True)
            (source/'rtl/mem/ven_l1d.sv').write_text(self.source)
            (source/'retain').write_text('unchanged\n')
            result = prepare(source, Path(name)/'candidate')
            self.assertFalse(result['standard_suite'])
            self.assertIsNone(result['gameplay_ipc'])
            with self.assertRaises(ValueError):
                prepare(source, source/'nested')
            with self.assertRaises(FileExistsError):
                prepare(source, Path(name)/'candidate')


if __name__ == '__main__':
    unittest.main()
