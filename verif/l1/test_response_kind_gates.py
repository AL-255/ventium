import unittest

import run_response_kind_core_checks as checks
import run_response_kind_same_input as replay
import run_response_kind_system as system


class GateBindings(unittest.TestCase):
    def test_comparison_policy_unchanged(self):
        text = checks.derive()
        original = checks.SOURCE.read_text()
        marker = "    if a.mode=='canonical':"
        self.assertEqual(text[text.index(marker):], original[original.index(marker):])
        self.assertIn("started['changes']==[recipe.FILE]", text)

    def test_replay_exact_reversal(self):
        text = replay.derive()
        for before, after in reversed(replay.REPLACEMENTS):
            self.assertEqual(text.count(after), 1)
            text = text.replace(after, before)
        pin = '\n    pins['+repr(str(replay.SOURCE))+']='+repr(replay.SOURCE_SHA)
        self.assertEqual(text.count(pin), 1)
        self.assertEqual(text.replace(pin, ''), replay.SOURCE.read_text())

    def test_system_corpus_unchanged_and_importable(self):
        text = system.derive()
        original = system.ORIGINAL.read_text()
        marker = "    specs=[('psysfpbounded'"
        self.assertEqual(text[text.index(marker):], original[original.index(marker):])
        namespace = dict(vars(system), __name__='import_only')
        exec(compile(text, '<system-import-check>', 'exec'), namespace)
        self.assertTrue(callable(namespace['main']))


if __name__ == '__main__':
    unittest.main()
