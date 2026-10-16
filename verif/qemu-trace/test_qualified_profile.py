"""Exact composition and rejection of unqualified reference identities."""
import copy
import json
import os
from pathlib import Path
import unittest

import qualified_profile as profile


class Profile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['QEMU_PROFILE_SOURCE']).resolve(strict=True)
        cls.build = Path(os.environ['QEMU_PROFILE_BUILD']).resolve(strict=True)
        cls.inputs = {n:(cls.source/n).read_text() for n in profile.AFTER}
        cls.closed = json.loads((cls.build/'closed.json').read_text())
        cls.sources = json.loads((cls.build/'source.json').read_text())['after']

    def test_full_closure_and_exact_previously_qualified_sources(self):
        self.assertEqual(profile.check_source(self.source)['after'],profile.AFTER_TREE)
        for name, text in profile.compose(self.inputs).items():
            self.assertEqual(text,(self.build/'source'/name).read_text())

    def test_drift_and_reapplication_fail_closed(self):
        for name in self.inputs:
            drift = dict(self.inputs);drift[name] += '\n'
            with self.assertRaises(ValueError):profile.compose(drift)
        with self.assertRaises(ValueError):profile.compose(profile.compose(self.inputs))

    def test_real_selected_binary(self):
        self.assertEqual(profile.sha(profile.select(self.build)),profile.BINARY)

    def test_unqualified_receipt_and_source_rejected(self):
        for field, value in (('passed',False),('pins_unchanged',False),('sha256','0'*64),('source_files',1)):
            changed=copy.deepcopy(self.closed);changed[field]=value
            with self.assertRaises(ValueError):profile.validate_receipt(changed,self.sources)
        changed=dict(self.sources);changed['target/i386/tcg/fpu_helper.c']='0'*64
        with self.assertRaises(ValueError):profile.validate_receipt(self.closed,changed)

    def test_no_path_traversal_or_partial_profile(self):
        with self.assertRaises(ValueError):profile.closure({'../outside':'0'*64})
        with self.assertRaises(ValueError):profile.compose({'linux-user/syscall.c':self.inputs['linux-user/syscall.c']})


if __name__ == '__main__':unittest.main()
