import unittest
import run_response_kind_env_faults as faults


class FaultBinding(unittest.TestCase):
    def test_original_corpus_and_comparisons_preserved(self):
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
