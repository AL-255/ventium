"""No weakened acceptance or changed native lifecycle in strict replay."""
import inspect
import unittest
import run_strict_mf_delivery as replay


class Replay(unittest.TestCase):
    def test_narrow_adaptation(self):
        before = inspect.getsource(replay.base.main)
        after = replay.adapt(before)
        self.assertIn('len(rows) == 72', after)
        self.assertIn("all(r['passed'] for r in rows if r['model'] == 'branch')", after)
        for start, end in [('    def native(', '    begin, rows, errors'),
                           ('        for vector in vectors():', '        # The address-shape experiment')]:
            original = before[before.index(start):before.index(end)]
            self.assertIn(original, after)
        self.assertIn('asm.write_text(source(vector, waiter))', after)
        self.assertNotIn('expected_failure', after)


if __name__ == '__main__':
    unittest.main()
