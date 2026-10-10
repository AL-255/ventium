import ast
import unittest
import run_high_window_core as driver


class AdapterTests(unittest.TestCase):
    def test_both_actual_corpora_keep_comparators_and_complete_cycles(self):
        for suite, path in (
            ('fp', driver.base.REPO/'verif/issue_uv/run-fp-high-payload-ab.py'),
            ('integer', driver.base.HERE/'run_store_warm_core.py')):
            original = path.read_text()
            expected = driver.base.adapt(original, suite)
            adapted = driver.adapt(original, suite)
            self.assertEqual(adapted.replace(driver.FLAG, driver.base.FLAG), expected)
            equality = (
                "assert cycle_observations[(latency,'control')] == cycle_observations[(latency,'candidate')]"
                if suite == 'fp' else
                "assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate']")
            self.assertIn(equality, adapted)
            self.assertIn('compare.compare_func(gold, trace,', adapted)
            ast.parse(adapted)

    def test_unknown_or_changed_corpus_refused(self):
        for suite in ('fp', 'integer', 'unknown'):
            with self.subTest(suite=suite), self.assertRaises(ValueError):
                driver.adapt('', suite)


if __name__ == '__main__':
    unittest.main()
