"""Check identity-only sequencer derivation without starting any tools."""
import ast
import unittest

import run_sfetch_boundary_timing_sequence as sequence


class Sequence(unittest.TestCase):
    def test_exact_owner_and_targets(self):
        invocation='0123456789abcdef0123456789abcdef'
        text=sequence.derive(invocation)
        ast.parse(text)
        self.assertIn("SYNTH_INVOCATION = '"+invocation+"'",text)
        for phase in ('synth','clock','timing-chain'):
            self.assertIn('ventium-sfetch-boundary-'+phase+'-oct16-r1.service',text)
        self.assertNotIn('posted-mouse-',text)

    def test_observation_and_native_lifecycle_unchanged(self):
        old=sequence.previous.derive('0'*32)
        new=sequence.derive('0'*32)
        for node in ast.parse(old).body:
            if isinstance(node,ast.FunctionDef):
                match=next(n for n in ast.parse(new).body if isinstance(n,ast.FunctionDef) and n.name==node.name)
                self.assertEqual(ast.get_source_segment(old,node).replace('posted-mouse-','sfetch-boundary-'),
                                 ast.get_source_segment(new,match))

    def test_invalid_invocation_rejected(self):
        for value in ('','a'*31,'A'*32,'a'*33,'a'*31+';'):
            with self.assertRaises(ValueError): sequence.derive(value)


if __name__=='__main__':unittest.main()
