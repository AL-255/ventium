"""Retain exact source closure, hardware mode, regression and resource guards."""
import os
from pathlib import Path
import unittest

import build_response_kind_soc as build
import freeze_response_kind_rk_candidate as freeze
import audit_response_kind_checks as audit


class Transfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['RESPONSE_KIND_HARDWARE_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['RESPONSE_KIND_CORE']).resolve(strict=True)

    def test_exact_core_match_and_drift_rejection(self):
        self.assertEqual(freeze.CHANGES, ['ventium/rtl/mem/ven_l1d.sv'])
        name = freeze.CHANGES[0]
        before = (self.parent/name).read_bytes()
        after = (self.core/name.removeprefix('ventium/')).read_bytes()
        self.assertTrue(freeze.check_delta(name, before, after))
        for left, right in ((before,before), (before,after+b'\n'), (before+b'\n',after), (after,after)):
            with self.assertRaises(Exception):
                freeze.check_delta(name, left, right)

    def test_other_sources_unchanged(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv', b'a', b'a'))
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/other.sv', b'a', b'b')

    def test_source_profile_and_resource_guards(self):
        _, text = build.derive()
        for line in (
            'assert len(shared) == 102',
            "assert [n for n in shared if sha(source / n) != sha(core / 'candidate' / n)] == CHANGES",
            'assert len(defs) == len(set(defs)) == 156',
            "assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command",
            "assert (audit['canonical_functional_passes'], audit['canonical_functional_failures']) == (7, 101)",
            "assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
            "assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']",
            "assert shutil.disk_usage(scratch).free > 5 * 1024**3"):
            self.assertIn(line, text)

    def test_audit_keeps_full_records_and_existing_failures(self):
        text = audit.derive()
        for line in (
            'assert r.records==tracefmt.read_trace(str(old_trace)).records==tracefmt.read_trace(str(new_trace)).records',
            "assert set(unmasked_failures)=={'tx_regform','tx_regform2','tx_stack'}",
            "assert vc['canonical_gate_passed']==(vc['canonical_gate_native_exit']==0)",
            'assert records==80800 and paired==30132 and parent_paired==30132',
            'assert not pair_deltas'):
            self.assertIn(line, text)


if __name__ == '__main__':
    unittest.main()
