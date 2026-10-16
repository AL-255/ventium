"""Check identity binding and the narrowly allowed oneshot observation phase."""
import ast
import unittest

import run_parallel_write_timing_sequence as sequence


class Sequence(unittest.TestCase):
    def test_exact_owner_and_targets(self):
        invocation = '0123456789abcdef0123456789abcdef'
        text = sequence.derive(invocation)
        ast.parse(text)
        self.assertIn("SYNTH_INVOCATION = '" + invocation + "'", text)
        for phase in ('synth', 'clock', 'timing-chain'):
            self.assertIn('ventium-parallel-write-' + phase + '-oct16-r1.service', text)
        self.assertNotIn('raw-prime-storage-', text)
        self.assertEqual(text.count(sequence.evidence.MANIFEST), 1)
        self.assertEqual(text.count(sequence.evidence.MODEL), 1)

    def test_lifecycle_changes_only_observation(self):
        old = sequence.previous.derive('0' * 32)
        new = sequence.derive('0' * 32)
        old_nodes = {n.name: n for n in ast.parse(old).body if isinstance(n, ast.FunctionDef)}
        new_nodes = {n.name: n for n in ast.parse(new).body if isinstance(n, ast.FunctionDef)}
        self.assertEqual(old_nodes.keys(), new_nodes.keys())
        for name in old_nodes.keys() - {'props', 'wait_closed'}:
            before = ast.get_source_segment(old, old_nodes[name])
            after = ast.get_source_segment(new, new_nodes[name])
            self.assertEqual(before.replace('raw-prime-storage-', 'parallel-write-'), after)

    def test_oneshot_phase_is_specific_to_synthesis(self):
        tree = ast.parse(sequence.derive('0' * 32))
        wait = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'wait_closed')
        check = next(n for n in ast.walk(wait) if isinstance(n, ast.Call) and
                     isinstance(n.func, ast.Name) and n.func.id == 'require' and
                     len(n.args) == 2 and isinstance(n.args[1], ast.BinOp) and
                     isinstance(n.args[1].left, ast.Constant) and
                     n.args[1].left.value == 'unexpected owner phase: ')
        predicate = compile(ast.Expression(check.args[0]), '<phase>', 'eval')
        for unit in ('synth', 'clock'):
            for kind in ('oneshot', 'exec'):
                for active in ('activating', 'active', 'failed'):
                    for sub in ('start', 'running', 'exited', 'failed'):
                        actual = eval(predicate, {'SYNTH': 'synth', 'unit': unit, 'state':
                            dict(Type=kind, ActiveState=active, SubState=sub)})
                        expected = sub == 'running' or (unit == 'synth' and kind == 'oneshot'
                            and active == 'activating' and sub == 'start')
                        self.assertEqual(actual, expected)

    def test_invalid_invocation_rejected(self):
        for value in ('', 'a' * 31, 'A' * 32, 'a' * 33, 'a' * 31 + ';'):
            with self.assertRaises(ValueError):
                sequence.derive(value)


if __name__ == '__main__':
    unittest.main()
