"""The new clock sequencer changes identities only, not the ownership protocol."""
import unittest
import run_demand_size_timing_sequence as sequence


class Sequence(unittest.TestCase):
    def test_identity_only(self):
        invocation = '1'*32
        source = sequence.derive(invocation)
        restored = source.replace('demand-size-', 'decode-bus-')
        for old, new in (
            (invocation, '26931169bdb9480fa5bc8264a68a4ed8'),
            ('d35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315',
             '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'),
            ('20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d',
             '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'),
        ):
            self.assertEqual(restored.count(old), 1)
            restored = restored.replace(old, new)
        self.assertEqual(restored, sequence.ORIGINAL.read_text())
        compile(source, '<demand-size-clock-sequence>', 'exec')

    def test_exact_invocation_required(self):
        for invalid in ('', '1'*31, '1'*33, 'g'*32):
            with self.assertRaises(ValueError):
                sequence.derive(invalid)


if __name__ == '__main__':
    unittest.main()
