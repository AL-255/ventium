"""Preparation-only tests: no guest, compiler or board access."""
from pathlib import Path
import types
import unittest
from unittest.mock import patch

import prepare_raw_prime_storage_win95 as current


class Preparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        template = current.previous.q.PARENT/'run_win95_cold.py'
        assert current.previous.sha(template) == current.previous.q.TEMPLATES['run_win95_cold.py']
        cls.original = template.read_text()
        cls.soc = current.ROOT/'nonexecuted-win95-fixture'
        cls.code = current.derive(cls.original, cls.soc, {})
        cls.runner = types.ModuleType('raw_storage_fixture')
        exec(compile(cls.code, '<fixture>', 'exec'), cls.runner.__dict__)

    def test_only_model_and_owner_change_after_existing_adapter(self):
        restored = self.code.replace(current.MODEL, current.previous.q.MODEL)
        restored = restored.replace(current.UNIT, current.previous.UNIT)
        self.assertEqual(restored, current.previous.derive(self.original, self.soc, {}))

    def test_command_environment_and_guest_unmodified(self):
        parent = types.ModuleType('parent_fixture')
        exec(compile(self.original, '<parent>', 'exec'), parent.__dict__)
        out = Path('/nonexecuted/win95-cold-fixture')
        self.assertEqual(self.runner.command(out), parent.command(out))
        self.assertEqual(self.runner.clean_environment(out), parent.clean_environment(out))
        for flag in ('--restore', '--ui-fifo', '--kb', '--ven-break', '--l1dis'):
            self.assertNotIn(flag, self.runner.command(out))
        self.assertEqual(self.runner.DISK_SHA, parent.DISK_SHA)
        self.assertEqual(self.runner.ROM_SHAS, parent.ROM_SHAS)

    def test_original_safety_and_nonacceptance_remain(self):
        for token in ('shutil.disk_usage(HERE).free >= 8 * 1024**3',
                      'shutil.disk_usage(stop.parent).free < 4 * 1024**3',
                      "values['pids.max'] == '160'", 'process.wait()',
                      "return 'CLOSED_UNQUALIFIED'", "'candidate input drift: '"):
            self.assertIn(token, self.code)
        self.assertEqual((self.runner.CPU, self.runner.CYCLES, self.runner.SECONDS),
                         (10, 9000000000, 259200))

    def test_wrong_candidate_is_rejected(self):
        with patch.object(current.controls, 'selected_model', return_value='stale-model'):
            with self.assertRaises(AssertionError):
                current.check_controls(self.soc)

    def test_template_drift_is_rejected(self):
        with patch.object(current.previous, 'sha', return_value='drift'):
            with self.assertRaises(AssertionError):
                current.derive(self.original, self.soc, {})


if __name__ == '__main__':
    unittest.main()
