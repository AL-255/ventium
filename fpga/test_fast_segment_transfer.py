"""Reject unreviewed export deltas and retain the complete hardware profile."""
import os
from pathlib import Path
import unittest

import build_fast_segment_soc as build
import freeze_fast_segment_rk_candidate as freeze


class Transfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent=Path(os.environ['FAST_SEGMENT_HARDWARE_PARENT']).resolve(strict=True)
        cls.core=Path(os.environ['FAST_SEGMENT_CORE']).resolve(strict=True)

    def test_exact_core_match(self):
        self.assertEqual(freeze.CHANGES,['ventium/rtl/core/core.sv'])
        name=freeze.CHANGES[0]
        self.assertTrue(freeze.check_delta(name,(self.parent/name).read_bytes(),
            (self.core/name.removeprefix('ventium/')).read_bytes()))

    def test_missing_drift_reapplication(self):
        name=freeze.CHANGES[0]
        before=(self.parent/name).read_bytes()
        after=(self.core/name.removeprefix('ventium/')).read_bytes()
        for a,b in ((before,before),(before,after+b'\n'),(before+b'\n',after),(after,after)):
            with self.subTest(a=len(a),b=len(b)):
                with self.assertRaises(Exception):freeze.check_delta(name,a,b)

    def test_unchanged_other_sources(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv',b'a',b'a'))
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/other.sv',b'a',b'b')

    def test_full_source_mode_resource_guards(self):
        _,text=build.derive()
        for line in (
            'assert len(shared) == 102',
            'assert [n for n in shared if sha(source / n) != sha(core / \'candidate\' / n)] == CHANGES',
            'assert len(defs) == len(set(defs)) == 156',
            "assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command",
            "assert (audit['canonical_functional_passes'], audit['canonical_functional_failures']) == (7, 101)",
            "assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
            "assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']",
            "assert shutil.disk_usage(scratch).free > 5 * 1024**3"):
            self.assertIn(line,text)


if __name__=='__main__':unittest.main()
