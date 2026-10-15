"""Sequence adaptation may change identities, never wait or acceptance rules."""
import unittest
import run_pipe_wait_timing_sequence as sequence


class Sequence(unittest.TestCase):
    def test_exact_identity_changes(self):
        invocation = '1'*32
        text = sequence.derive(invocation)
        restored = text.replace('pipe-wait-', 'demand-size-')
        for old, new in (
            ('d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc',
             'd35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315'),
            ('55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce',
             '20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d'),
        ):
            restored = restored.replace(old, new)
        self.assertEqual(restored, sequence.previous.derive(invocation))
        compile(text, '<pipe-wait-sequence>', 'exec')

    def test_explicit_owner_required(self):
        for bad in ('', 'a'*31, 'g'*32, '1'*33):
            with self.assertRaises(ValueError): sequence.derive(bad)


if __name__ == '__main__':
    unittest.main()
