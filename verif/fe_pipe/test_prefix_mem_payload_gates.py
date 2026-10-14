"""Gate adapters bind candidate identity without altering comparison policy."""
import unittest

import run_prefix_mem_payload_checks as checks
import run_prefix_mem_payload_same_input as replay


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


if __name__ == '__main__':
    unittest.main()
