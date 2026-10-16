import ast
import unittest
from unittest.mock import patch
import system_read_ack_controls as controls


class Controls(unittest.TestCase):
    def test_only_identity_changes(self):
        for action in controls.TEMPLATES:
            source=controls.derive(action);ast.parse(source)
            for old,new in reversed(controls.changes(action)):
                source=source.replace(new,old)
            self.assertEqual(source,controls.previous_controls.derive(action))

    def test_drift_fails_closed(self):
        with patch.object(controls.build,'sha',return_value='drift'):
            for action in controls.TEMPLATES:
                with self.assertRaises(AssertionError):controls.derive(action)

    def test_limits_grading_and_duration_caveat_unchanged(self):
        text=controls.derive('coremark')
        for token in ("{'performance':4771298,'validation':4755366}",
                      'require_valid_duration=False','max_workers=2','rc=child.wait(timeout=600)',
                      "assert '[UI-' not in text"):
            self.assertIn(token,text)
        text=controls.derive('input')
        for token in ('grade(text,raw)','begin<480','os.sched_getaffinity(0)=={16,17}',
                      'max_workers=2','actual_wait=True'):
            self.assertIn(token,text)
        self.assertIs(controls.namespace('input','model')['grade'],
                      controls.TEMPLATES['input'][0].previous.grade)


if __name__=='__main__':unittest.main()
