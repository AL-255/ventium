#!/usr/bin/env python3
"""FP-only cofactor must not alter integer AGI/reference priming."""
import os
from pathlib import Path
import unittest
from prepare_fp_nomem_exec import OLD, INSERT, FAST_OLD, FAST_NEW, transform


class Recipe(unittest.TestCase):
    def setUp(self):
        self.parent=Path(os.environ['FP_NOMEM_PARENT']).read_text()

    def test_exact_two_edits(self):
        candidate=transform(self.parent)
        self.assertEqual(candidate.replace(OLD+INSERT,OLD).replace(FAST_NEW,FAST_OLD),self.parent)

    def test_shared_integer_permit_unchanged(self):
        candidate=transform(self.parent)
        self.assertEqual(candidate.count(OLD),1)
        self.assertIn('!pipe_mem_wait;',OLD)
        self.assertNotIn('pipe_mem_wait',INSERT.split('  assign pipe_fp_nomem_arm =',1)[1].split(';',1)[0])

    def test_drift_rejected(self):
        for text in (self.parent+'\n',self.parent.replace(OLD,OLD.replace('!pipe_mem_active_q',"1'b1"))):
            with self.assertRaises(ValueError):transform(text)

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):transform(transform(self.parent))


if __name__=='__main__':unittest.main()
