"""Reject missing/drifted/extra RTL changes and retain full-PC build guards."""
import ast
import os
from pathlib import Path
import unittest

import build_way_banked_soc as build
import freeze_way_banked_rk_candidate as freeze


class Transfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent=Path(os.environ['WAY_BANKED_HARDWARE_PARENT']).resolve(strict=True)
        cls.core=Path(os.environ['WAY_BANKED_CORE']).resolve(strict=True)

    def test_exact_core_match(self):
        self.assertEqual(freeze.CHANGES,['ventium/rtl/core/core.sv','ventium/rtl/mem/ven_l1d.sv'])
        for name in freeze.CHANGES:
            with self.subTest(name=name):
                self.assertTrue(freeze.check_delta(name,(self.parent/name).read_bytes(),
                    (self.core/name.removeprefix('ventium/')).read_bytes()))

    def test_missing_drift_reapplication(self):
        for name in freeze.CHANGES:
            before=(self.parent/name).read_bytes()
            after=(self.core/name.removeprefix('ventium/')).read_bytes()
            for a,b in ((before,before),(before,after+b'\n'),(before+b'\n',after),(after,after)):
                with self.subTest(name=name,a=len(a),b=len(b)):
                    with self.assertRaises(Exception):freeze.check_delta(name,a,b)

    def test_unchanged_other_sources(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv',b'a',b'a'))
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/other.sv',b'a',b'b')

    def test_full_source_and_mode_guards(self):
        _,text=build.derive()
        for line in (
            'assert len(shared) == 102',
            'assert [n for n in shared if sha(source / n) != sha(core / \'candidate\' / n)] == CHANGES',
            'assert len(defs) == len(set(defs)) == 156',
            "assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command",
            "assert (audit['canonical_functional_passes'], audit['canonical_functional_failures']) == (7, 101)",
            "assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
            "command[affinity+2] = '0-9,12-31'"):
            self.assertIn(line,text)
        old=ast.parse(build.original.read_text());new=ast.parse(text)
        main=lambda tree:next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
        self.assertEqual(ast.dump(main(old)),ast.dump(main(new)))


if __name__=='__main__':unittest.main()
