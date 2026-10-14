"""Gate adapters bind candidate identity without altering comparison policy."""
import unittest

import run_prefix_mem_payload_checks as checks
import run_prefix_mem_payload_same_input as replay
import run_prefix_mem_payload_system as system
import run_prefix_mem_payload_env_faults as faults


class GateBindings(unittest.TestCase):
    def test_comparison_policy_unchanged(self):
        text = checks.derive()
        original = checks.SOURCE.read_text()
        marker = "    if a.mode=='canonical':"
        self.assertEqual(text[text.index(marker):], original[original.index(marker):])
        self.assertIn("(parent/'candidate'/recipe.DECODER_FILE).read_text()", text)
        self.assertIn("started['changes']==[recipe.FILE]", text)

    def test_replay_exact_reversal(self):
        text = replay.derive()
        for before, after in reversed(replay.REPLACEMENTS):
            self.assertEqual(text.count(after), 1)
            text = text.replace(after, before)
        pin = '\n    pins['+repr(str(replay.SOURCE))+']='+repr(replay.SOURCE_SHA)
        self.assertEqual(text.count(pin), 1)
        self.assertEqual(text.replace(pin, ''), replay.SOURCE.read_text())

    def test_system_fixtures_and_comparisons_unchanged(self):
        text = system.derive()
        original = system.ORIGINAL.read_text()
        marker = "    specs=[('psysfpbounded'"
        self.assertEqual(text[text.index(marker):], original[original.index(marker):])
        self.assertIn("ORIGINAL.with_name('run_leaf.py')", text)
        # Verify the import environment as well as the string adaptation.
        namespace = dict(vars(system), __name__='import_only')
        exec(compile(text, '<system-import-check>', 'exec'), namespace)
        self.assertTrue(callable(namespace['main']))

    def test_environment_fault_corpus_unchanged(self):
        text = faults.derive()
        original = faults.SOURCE.read_text()
        marker = '    cases = [dict(FULL='
        self.assertEqual(text[text.index(marker):], original[original.index(marker):])
        self.assertIn("len(parent_files)==len(actual_files)==195", text)
        self.assertIn("before['changes']==[recipe.FILE]", text)
        namespace = dict(vars(faults), __name__='import_only')
        exec(compile(text, '<fault-import-check>', 'exec'), namespace)
        self.assertTrue(callable(namespace['main']))


if __name__ == '__main__':
    unittest.main()
