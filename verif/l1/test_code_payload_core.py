"""Adapter guard tests; actual processor qualification is separate."""
import ast
import unittest
import run_code_payload_core as driver


class Tests(unittest.TestCase):
    def test_both_corpora_keep_exact_compare_and_cycles(self):
        for suite,path in (
            ('fp',driver.base.REPO/'verif/issue_uv/run-fp-high-payload-ab.py'),
            ('integer',driver.base.HERE/'run_store_warm_core.py')):
            original=path.read_text()
            expected=driver.base.adapt(original,suite)
            adapted=driver.adapt(original,suite)
            self.assertEqual(adapted.replace(driver.FLAG,driver.base.FLAG),expected)
            equality=("assert cycle_observations[(latency,'control')] == cycle_observations[(latency,'candidate')]"
                if suite=='fp' else "assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate']")
            self.assertIn(equality,adapted)
            self.assertIn('compare.compare_func(gold, trace,',adapted)
            ast.parse(adapted)

    def test_drifted_or_unknown_refused(self):
        for suite in ('fp','integer','unknown'):
            with self.subTest(suite=suite),self.assertRaises(ValueError): driver.adapt('',suite)


if __name__=='__main__': unittest.main()
