import os
from pathlib import Path
import unittest

import build_prefix_opcode_soc as build
import freeze_prefix_opcode_rk_candidate as freeze


class Transfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent=Path(os.environ['PREFIX_OPCODE_HARDWARE_PARENT']).resolve(strict=True)
        cls.core=Path(os.environ['PREFIX_OPCODE_CORE']).resolve(strict=True)

    def test_exact_delta_and_drift(self):
        self.assertEqual(freeze.CHANGES,['ventium/rtl/core/decode_stages.sv'])
        name=freeze.CHANGES[0]
        before=(self.parent/name).read_bytes()
        after=(self.core/name.removeprefix('ventium/')).read_bytes()
        self.assertTrue(freeze.check_delta(name,before,after))
        for left,right in ((before,before),(before,after+b'\n'),(before+b'\n',after),(after,after)):
            with self.assertRaises(Exception): freeze.check_delta(name,left,right)

    def test_other_files_unchanged(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv',b'a',b'a'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/other.sv',b'a',b'b')

    def test_source_profile_and_resource_guards(self):
        _,text=build.derive()
        for line in (
            'assert len(shared) == 102',
            "assert [n for n in shared if sha(source / n) != sha(core / 'candidate' / n)] == CHANGES",
            'assert len(defs) == len(set(defs)) == 156',
            "assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command",
            "assert (audit['canonical_functional_passes'], audit['canonical_functional_failures']) == (7, 101)",
            "assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
            "assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']",
            "assert shutil.disk_usage(scratch).free > 5 * 1024**3"):
            self.assertIn(line,text)


if __name__=='__main__': unittest.main()
