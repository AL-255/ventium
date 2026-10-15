"""The early candidate changes only the one-shot sequence's identities."""
import ast
import unittest

import run_early_bus_timing_sequence as seq


class Sequence(unittest.TestCase):
    def test_identity_only(self):
        old = seq.ORIGINAL.read_text()
        new = seq.derive('a'*32)
        ast.parse(new)
        for name in ('props', 'wait_closed'):
            def source(text):
                node = next(n for n in ast.parse(text).body
                            if isinstance(n, ast.FunctionDef) and n.name == name)
                return ast.get_source_segment(text, node)
            self.assertEqual(source(old), source(new))
        self.assertNotIn('decode-bus-', new)
        self.assertIn("SYNTH_INVOCATION = '"+'a'*32+"'", new)
        self.assertIn('no_synthesis_or_implementation_launch=True', new)

    def test_invalid_invocation(self):
        for value in ('', 'a'*31, 'g'*32, 'a'*32+'\n'):
            with self.assertRaises(ValueError): seq.derive(value)


if __name__ == '__main__': unittest.main()
