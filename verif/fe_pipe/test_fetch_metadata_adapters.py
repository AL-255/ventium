"""Check identity-only changes to the existing verification drivers."""
from pathlib import Path
import unittest

import run_fetch_metadata_checks as checks


class Adapters(unittest.TestCase):
    def test_preserve_native_comparisons(self):
        for mode in checks.SOURCES:
            text, changes, source = checks.derive(mode,Path('/candidate'),Path('/parent'),
                'f'*64,Path('/functional'),Path('/output'),Path('/jobs'))
            for before,after in reversed(changes):
                self.assertEqual(text.count(after),1)
                text=text.replace(after,before)
            self.assertEqual(text,source.read_text())


if __name__=='__main__':unittest.main()
