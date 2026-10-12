import unittest

from prepare_ps2_arm_fixture import adapt_scratch


class ScratchAdapterTests(unittest.TestCase):
    def setUp(self):
        self.line = "self.assertEqual(scratch, Path('/home/yukidama/external/tmp').resolve(strict=True))"

    def test_only_exact_root_changes(self):
        before = '# before\n' + self.line + '\n# after\n'
        after = adapt_scratch(before)
        self.assertEqual(after, before.replace("Path('/home/yukidama/external/tmp')",
                                               "Path(os.environ['VEN_PS2_TEST_ROOT'])"))
        self.assertIn('self.assertEqual', after)

    def test_missing_duplicate_or_drift_rejected(self):
        for source in ('', self.line*2, self.line.replace('strict=True', 'strict=False')):
            with self.assertRaises(ValueError):
                adapt_scratch(source)

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):
            adapt_scratch(adapt_scratch(self.line))


if __name__ == '__main__':
    unittest.main()
