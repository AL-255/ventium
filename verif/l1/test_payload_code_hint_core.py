"""Admission tests only; native whole-core qualification remains required."""
import ast
import unittest

import run_payload_code_hint_core as driver


class Tests(unittest.TestCase):
    def test_matrix_only_changes_one_admitted_flag(self):
        for suite in ('fp', 'integer'):
            source = driver.SOURCES[suite].read_text()
            expected = driver.base.adapt(source, suite)
            adapted = driver.adapt(source, suite)
            self.assertEqual(adapted.replace(driver.FLAG, driver.base.FLAG), expected)
            self.assertIn('compare.compare_func(gold, trace,', adapted)
            self.assertIn('missing actual U/V pair', adapted)
            equality = ("assert cycle_observations[(latency,'control')] == cycle_observations[(latency,'candidate')]"
                        if suite == 'fp' else
                        "assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate']")
            self.assertIn(equality, adapted)
            ast.parse(adapted)

    def test_fault_corpus_unchanged_except_profile_and_location(self):
        source = driver.SOURCES['faults'].read_text()
        adapted = driver.adapt(source, 'faults')
        restored = adapted.replace('REPO = Path('+repr(str(driver.base.REPO))+')',
                                   'REPO = Path(__file__).resolve().parents[2]')
        restored = restored.replace('    assert '+repr(driver.FLAG)+' not in profiles[0]\n'
            '    assert profiles[1] == profiles[0] | {'+repr(driver.FLAG)+'}',
            '    assert profiles[0] == profiles[1]')
        self.assertEqual(restored, source)
        self.assertIn("if records['control'] != records['candidate']:", adapted)
        self.assertIn("'--mode', 'func', '--all'", adapted)
        self.assertIn('len(result[\'measurements\']) == 32', adapted)
        self.assertIn('pass_fds=(9,)', adapted)
        ast.parse(adapted)

    def test_profile_rejects_any_other_difference(self):
        adapted = driver.adapt(driver.SOURCES['faults'].read_text(), 'faults')
        checks = '\n'.join(line.strip() for line in adapted.splitlines()
                           if line.startswith('    assert ') and 'profiles[' in line)
        control = {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC'}
        candidate = control | {driver.FLAG}
        exec(checks, {'profiles': [control, candidate]})
        for bad in (control, candidate | {'UNRELATED'}, candidate - {'VEN_FE_PIPE'}):
            with self.subTest(candidate=bad), self.assertRaises(AssertionError):
                exec(checks, {'profiles': [control, bad]})
        with self.assertRaises(AssertionError):
            exec(checks, {'profiles': [candidate, candidate]})

    def test_source_drift_or_unknown_suite_fails(self):
        for suite in (*driver.SOURCES, 'unknown'):
            with self.subTest(suite=suite), self.assertRaises(ValueError):
                driver.adapt('', suite)
        source = driver.SOURCES['faults'].read_text()
        for changed in (source.replace('    assert profiles[0] == profiles[1]', ''),
                        source+'\n    assert profiles[0] == profiles[1]\n'):
            with self.assertRaises(ValueError):
                driver.adapt(changed, 'faults')


if __name__ == '__main__':
    unittest.main()
