"""Identity-only cold-run adaptation and fail-closed acceptance controls."""
import copy
import types
import unittest

import prepare_decode_bus_cold as prepare


class Cold(unittest.TestCase):
    def setUp(self):
        self.original = {}
        for name, digest in prepare.parent.TEMPLATES.items():
            path = prepare.parent.PARENT/name
            self.assertEqual(prepare.sha(path), digest)
            self.original[name] = path.read_text()
        self.outputs = prepare.derive(self.original, prepare.ROOT/'decode-bus-soc-r1', {})
        self.module = types.ModuleType('cold_candidate_test')
        exec(compile(self.outputs['run_quake_cold.py'], '<prepared-test>', 'exec'), self.module.__dict__)

    def test_only_identity_changes(self):
        model = prepare.parent.MODEL
        try:
            prepare.parent.MODEL = prepare.MODEL
            expected = prepare.parent.derive(self.original, prepare.ROOT/'decode-bus-soc-r1', {})
        finally:
            prepare.parent.MODEL = model
        for name, text in self.outputs.items():
            if name == 'run_quake_cold.py':
                text = text.replace(repr(prepare.LEAF), "'quake-cold-fp-repair-oct13.1'")
                text = text.replace(repr(prepare.UNIT), "'ventium-fp-repair-quake-oct13.service'")
            self.assertEqual(text, expected[name])
        self.assertEqual(self.module.MODEL_SHA, prepare.MODEL)
        self.assertEqual((self.module.CPU, self.module.CYCLES, self.module.SECONDS),
                         (11, 30000000000, 259200))
        guard = self.outputs['run_win95_cold.py']
        self.assertIn("resource helper only; Win95 launch not prepared here", guard)
        self.assertIn("values['pids.max'] == '160'", guard)
        self.assertIn('6 * 1024**3', self.outputs['run_quake_cold.py'])
        self.assertIn('4 * 1024**3', self.outputs['cold-helpers/run_quake_standard.py'])

    def test_partial_or_tainted_completion_rejected(self):
        good = dict(status='PASS', sim_returncode=0, process_group_absent_after_wait=True,
                    result={'frames': 969}, log_capture=dict(actual_child_wait=True,
                    sim_returncode=0, pipe_eof=True, sticky_error=None,
                    captured_bytes=100, persisted_bytes=100))
        self.module.validate_closed(good, 0)
        for where, key, value in (
            (None, 'status', 'OBSERVED_UNQUALIFIED'), (None, 'sim_returncode', 1),
            (None, 'process_group_absent_after_wait', False), ('result', 'frames', 968),
            ('log_capture', 'actual_child_wait', False), ('log_capture', 'pipe_eof', False),
            ('log_capture', 'sticky_error', 'truncated'), ('log_capture', 'persisted_bytes', 99),
            ('log_capture', 'captured_bytes', 0),
        ):
            bad = copy.deepcopy(good)
            (bad if where is None else bad[where])[key] = value
            with self.subTest(where=where, key=key), self.assertRaises(ValueError):
                self.module.validate_closed(bad, 0)
        with self.assertRaises(ValueError):
            self.module.validate_closed(good, 1)


if __name__ == '__main__':
    unittest.main()
