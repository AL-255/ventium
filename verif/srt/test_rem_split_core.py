"""Fail closed on profile drift; preserve original corpus checks verbatim."""
import unittest
import run_rem_split_core as run


class AdapterTests(unittest.TestCase):
    def test_all_cold_suites_only_change_added_flag(self):
        for suite, source in run.corpus.SOURCES.items():
            with self.subTest(suite=suite):
                original = source.read_text()
                old = run.corpus.adapt(original, suite)
                new = run.adapt(original, suite)
                self.assertEqual(new.replace(repr(run.FLAG), repr(run.corpus.FLAG)), old)
                self.assertNotIn(repr(run.corpus.FLAG), new)
                compile(new, str(source), 'exec')

    def test_canonical_preserves_complete_replay(self):
        original = run.Path(run.canonical.__file__).read_text()
        new = run.adapt(original, 'canonical')
        for line in original.splitlines():
            if 'assert profiles[0]==profiles[1]' not in line:
                self.assertIn(line, new)
        self.assertIn('len(profiles[0]) == 151', new)
        self.assertIn("require_identical(traces['control'],traces['candidate'])", new)
        compile(new, 'canonical', 'exec')
        with self.assertRaises(ValueError):
            run.adapt(original.replace('len(profiles[0])==150', 'len(profiles[0])==149'), 'canonical')


if __name__ == '__main__':
    unittest.main()
