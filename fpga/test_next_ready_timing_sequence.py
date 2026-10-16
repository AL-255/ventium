import ast
import unittest

import run_next_ready_timing_sequence as sequence


class Sequence(unittest.TestCase):
    def test_identity_only_change(self):
        old = sequence.previous.derive('0'*32); new = sequence.derive('0'*32)
        a, b = ast.parse(old), ast.parse(new)
        for node in a.body:
            if isinstance(node, ast.FunctionDef):
                match = next(n for n in b.body if isinstance(n,ast.FunctionDef) and n.name==node.name)
                self.assertEqual(ast.get_source_segment(old,node).replace('sfetch-boundary-','next-ready-'),
                                 ast.get_source_segment(new,match))
        for phase in ('synth','clock','timing-chain'):
            self.assertIn('ventium-next-ready-'+phase+'-oct16-r1.service',new)
        self.assertIn(sequence.evidence.MANIFEST,new)
        self.assertIn(sequence.evidence.MODEL,new)

    def test_invalid_owner_rejected(self):
        for value in ('', 'a'*31, 'A'*32, 'a'*33, 'a'*31+';'):
            with self.assertRaises(ValueError): sequence.derive(value)


if __name__ == '__main__': unittest.main()
