"""Exact-delta export checks; preserve hardware mode and resource contracts."""
import os
from pathlib import Path
import unittest

import build_prefix_payload_soc as build
import freeze_prefix_payload_rk_candidate as freeze
import audit_prefix_mem_payload_checks as audit
import prepare_prefix_payload_synthesis as timing


class Transfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['PREFIX_PAYLOAD_HARDWARE_PARENT']).resolve(strict=True)
        cls.core = Path(os.environ['PREFIX_PAYLOAD_CORE']).resolve(strict=True)

    def test_exact_core_match(self):
        self.assertEqual(freeze.CHANGES, ['ventium/rtl/core/core_prefix66_decode.svh'])
        name = freeze.CHANGES[0]
        self.assertTrue(freeze.check_delta(name, (self.parent/name).read_bytes(),
                                          (self.core/name.removeprefix('ventium/')).read_bytes()))

    def test_missing_drift_reapplication(self):
        name = freeze.CHANGES[0]
        before = (self.parent/name).read_bytes()
        after = (self.core/name.removeprefix('ventium/')).read_bytes()
        for left, right in ((before,before), (before,after+b'\n'), (before+b'\n',after), (after,after)):
            with self.assertRaises(Exception):
                freeze.check_delta(name, left, right)

    def test_unchanged_other_sources(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv', b'a', b'a'))
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/other.sv', b'a', b'b')

    def test_full_source_mode_resource_guards(self):
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

    def test_audit_retains_full_records_and_known_failures(self):
        text = audit.derive()
        for line in (
            'assert r.records==tracefmt.read_trace(str(old_trace)).records==tracefmt.read_trace(str(new_trace)).records',
            "assert set(unmasked_failures)=={'tx_regform','tx_regform2','tx_stack'}",
            "assert vc['canonical_gate_passed']==(vc['canonical_gate_native_exit']==0)",
            'assert records==80800 and paired==30132 and parent_paired==30132',
            'assert not pair_deltas'):
            self.assertIn(line, text)

    def test_native_timing_lifecycle_unchanged(self):
        original = {name:(timing.ROOT/name).read_text() for name in timing.TEMPLATES}
        generated = timing.derive(original)
        for phase in ('synthesis','clock'):
            before = original['fast-segment-'+phase+'-r2/run.py']
            after = generated['prefix-payload-'+phase+'-r1/run.py']
            marker = 'owner = None\n'
            self.assertEqual(before[before.index(marker):], after[after.index(marker):])
        synth = generated['prefix-payload-synthesis-r1/run.py']
        for assertion in (
            "assert not boundary['passed'] and boundary['errors']",
            "assert not prepared['canonical_gate_passed']",
            "leaf['profiles'][1]['definitions']==json.loads((core/'build-started.json').read_text())['definitions']",
            "assert shutil.disk_usage(root).free > 6*gib",
            'assert shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth'):
            self.assertIn(assertion,synth)

    def test_timing_guard_rejects_relaxed_caps(self):
        original = {name:(timing.ROOT/name).read_text() for name in timing.TEMPLATES}
        generated = timing.derive(original)
        synth = generated['prefix-payload-synthesis-r1/run.py']
        for before, after in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                              ('if free < 4*gib:', 'if free < 1*gib:'),
                              ('memory+swap > 13*gib', 'memory+swap > 24*gib')):
            with self.assertRaises(AssertionError):
                timing.guarded(synth.replace(before,after),original['fast-segment-synthesis-r2/run.py'])


if __name__ == '__main__':
    unittest.main()
