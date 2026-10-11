"""Fail-closed source recipe tests; sequential equivalence is a separate gate."""
import os
from pathlib import Path
import re
import unittest
from prepare_qacc_init_payload import ANCHOR, REPLACEMENT, REM, DIV, transform


class QuotientInitialization(unittest.TestCase):
    def setUp(self):
        self.source=Path(os.environ['SRT_QACC_PARENT']).read_text()

    def test_exact_relocation(self):
        candidate=transform(self.source)
        # No other assignment, guard, declaration, state or interface changes.
        stripped=self.source.replace(REM,'').replace(DIV,'')
        self.assertEqual(candidate.replace(REPLACEMENT,ANCHOR),stripped)
        self.assertEqual(len(re.findall(r'qacc\s*<=',self.source)),6)
        self.assertEqual(len(re.findall(r'qacc\s*<=',candidate)),5)

    def test_drift_rejected(self):
        for bad in (self.source+'\n',transform(self.source),self.source.replace('if (start)','if (busy)')):
            with self.subTest(),self.assertRaises(ValueError):transform(bad)


if __name__=='__main__':unittest.main()
