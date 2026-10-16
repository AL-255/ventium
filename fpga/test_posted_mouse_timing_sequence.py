"""Inspect the derived sequence without starting any controller or tool."""
import ast
from pathlib import Path
import unittest

import run_posted_mouse_timing_sequence as seq


class Sequence(unittest.TestCase):
    def test_exact_owner_and_new_targets(self):
        invocation = '0123456789abcdef0123456789abcdef'
        text = seq.derive(invocation)
        ast.parse(text)
        self.assertIn("SYNTH_INVOCATION = '"+invocation+"'", text)
        for unit in ('synth', 'clock', 'timing-chain'):
            self.assertIn('ventium-posted-mouse-'+unit+'-oct16-r1.service', text)
        self.assertNotIn('decode-bus-', text)
        self.assertIn('posted-mouse-timing-prepared-r1.json', text)

    def test_wait_and_launch_lifecycle_identical(self):
        text = seq.derive('0'*32)
        old = Path(seq.__file__).with_name('run_decode_bus_timing_sequence.py').read_text()
        # Target names change; all observation/failure/launch logic must not.
        for node in ast.parse(old).body:
            if isinstance(node, ast.FunctionDef):
                a = ast.get_source_segment(old, node)
                new_node = next(n for n in ast.parse(text).body
                                if isinstance(n, ast.FunctionDef) and n.name == node.name)
                b = ast.get_source_segment(text, new_node)
                expected = a.replace('decode-bus-', 'posted-mouse-').replace(
                    'posted-mouse-timing-prepared.json', 'posted-mouse-timing-prepared-r1.json')
                self.assertEqual(expected, b)

    def test_bad_invocations_rejected(self):
        for value in ('', 'a'*31, 'A'*32, 'a'*33, 'a'*31+';'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                seq.derive(value)


if __name__ == '__main__':
    unittest.main()
