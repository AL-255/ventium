"""Rebinding cannot alter inputs, grading, runtime limits or timebases."""
import unittest

import parallel_write_controls as controls


class Controls(unittest.TestCase):
    def test_exact_reversal(self):
        for action in controls.TEMPLATES:
            text = controls.derive(action)
            for old, new in reversed(controls.changes(action)):
                text = text.replace(new, old)
            self.assertEqual(text, controls.prior_controls.derive(action))

    def test_limits_and_grades_unchanged(self):
        text = controls.derive('input')
        for token in ('grade(text,raw)', 'begin<480', 'os.sched_getaffinity(0)=={16,17}',
                      'max_workers=2', 'actual_wait=True'):
            self.assertIn(token, text)
        text = controls.derive('coremark')
        for token in ("{'performance':4771298,'validation':4755366}",
                      'require_valid_duration=False', 'max_workers=2', 'rc=child.wait(timeout=600)',
                      "assert '[UI-' not in text"):
            self.assertIn(token, text)


if __name__ == '__main__': unittest.main()
