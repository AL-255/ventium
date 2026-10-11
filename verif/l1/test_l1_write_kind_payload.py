"""Recipe checks. Native source-extracted comparison is a separate bounded run."""
import os
from pathlib import Path
import unittest
from prepare_l1_write_kind_payload import OLD, NEW, backing_block, transform


class WriteKindRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['L1_WRITE_KIND_PARENT']).read_text()

    def test_exact_reversible_delta(self):
        changed = transform(self.source)
        self.assertEqual(changed.replace(NEW, OLD), self.source)

    def test_refuse_source_drift(self):
        with self.assertRaises(ValueError):
            transform(self.source + '\n')

    def test_refuse_reapplication(self):
        with self.assertRaises(ValueError):
            transform(transform(self.source))

    def test_no_request_or_payload_edit(self):
        original, changed = backing_block(self.source), backing_block(transform(self.source))
        self.assertEqual(changed.replace(NEW, OLD), original)
        self.assertIn('m_req=c_pair_req && c_pair_ready;', OLD)
        self.assertIn('m_req=c_pair_req && c_pair_ready;', NEW)


if __name__ == '__main__':
    unittest.main()
