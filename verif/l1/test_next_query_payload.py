import os
from pathlib import Path
import unittest
from prepare_next_query_payload import OLD, NEW, transform, assignment, require_conjunct


class Recipe(unittest.TestCase):
    def setUp(self):
        self.source = Path(os.environ['NEXT_QUERY_PARENT']).read_text()

    def test_exact_edit(self):
        self.assertEqual(transform(self.source).replace(NEW, OLD), self.source)

    def test_drift_and_reapplication(self):
        for s in (self.source + '\n', transform(self.source)):
            with self.assertRaises(ValueError): transform(s)

    def test_request_commit_and_strobes_unchanged(self):
        changed = transform(self.source)
        for name in ('mem_next_req', 'mem_next_commit', 'mem_next_wstrb'):
            self.assertEqual(assignment(self.source, name), assignment(changed, name))

    def test_guard_checks(self):
        require_conjunct('valid && (a || (b ? c : d)) && !e', 'valid')
        for s in ('valid && a || b', 'valid && a ? b : c', 'valid && a ^ b',
                  'wrong && a', 'valid && (a', 'valid && a)'):
            with self.subTest(expr=s), self.assertRaises(ValueError): require_conjunct(s, 'valid')


if __name__ == '__main__': unittest.main()
