"""Repeat the unchanged all-input proof and actual SV tests on the new parent."""
import hashlib
from pathlib import Path
import sys
import unittest

import prepare_fetch_fault_page_current as recipe
import test_fetch_fault_page as previous

assert hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()==\
    'feb043ce62db5b4465fd05ee9013810bf4b0196602c7175cc1bd797d679a7542'
assert (recipe.OLD,recipe.NEW,recipe.PROBE_OLD,recipe.PROBE_NEW)==\
    (previous.patch.OLD,previous.patch.NEW,previous.patch.PROBE_OLD,previous.patch.PROBE_NEW)
previous.patch=recipe

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromModule(previous)
    assert suite.countTestCases()==3
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
