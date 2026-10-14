"""A retry may change output/owner names only, never guards or source inputs."""
import unittest
import prepare_response_kind_synthesis_retry as retry


class Retry(unittest.TestCase):
    def test_only_exact_renames(self):
        original = {}
        for name, digest in retry.TEMPLATES.items():
            path = retry.first.ROOT/name
            self.assertEqual(retry.first.sha(path), digest)
            original[name] = path.read_text()
        output = retry.derive(original)
        self.assertEqual(len(output), 5)
        for old_name, text in original.items():
            new_name = old_name
            for before, after in retry.RENAMES: new_name = new_name.replace(before, after)
            actual = output[new_name]
            for before, after in reversed(retry.RENAMES): actual = actual.replace(after, before)
            self.assertEqual(actual, text)


if __name__ == '__main__': unittest.main()
