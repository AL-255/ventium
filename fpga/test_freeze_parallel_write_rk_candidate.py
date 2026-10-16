"""Reject extra deltas, weakened native closure and false acceptance."""
import copy
import unittest

import freeze_parallel_write_rk_candidate as freeze
import lint_parallel_write_rk as lint
from freeze_rk_candidate import FreezeError


class Freeze(unittest.TestCase):
    def setUp(self):
        root = freeze.native.ROOT
        self.parent, self.soc = root/'raw-prime-storage-fpga-r1', root/'parallel-write-soc-r1'
        self.old = freeze.native.load(self.parent/'input-manifest.json')
        self.start = freeze.native.load(self.soc/'build-started.json')
        self.closed = freeze.native.load(self.soc/'build-closed.json')
        self.defs = (self.soc/'defines.txt').read_text().splitlines()

    def test_profile_and_red_gate_not_waived(self):
        freeze.check_profile(self.old, self.start, self.closed, self.defs)
        for field in ('canonical_gate_passed', 'legacy_aggregate_gate_passed'):
            wrong = copy.deepcopy(self.start); wrong[field] = True
            with self.assertRaises(FreezeError):
                freeze.check_profile(self.old, wrong, self.closed, self.defs)

    def test_all_payloads_preserved_except_exact_two_files(self):
        changed = []
        for row in self.old['files']:
            name = row['frozen']; before = (self.parent/name).read_bytes(); after = before
            if name in freeze.CHANGES:
                after = (self.soc/'source'/name.removeprefix('ventium/')).read_bytes()
            if freeze.check_delta(name, before, after): changed.append(name)
        self.assertEqual(sorted(changed), freeze.CHANGES)
        self.assertEqual(len(changed), 2)

    def test_native_seal_guards_retained(self):
        text = freeze.adapted_freeze()
        compile(text, freeze.__file__, 'exec')
        for token in ('compiled == 170', 'len(payload) == 192', 'source_closure',
                      'closed_owner(build_unit', "pins in (began['pins']", 'stable();',
                      'changed_flow_payloads=[]', 'full_wrapper_elaborated=False'):
            self.assertIn(token, text)

    def test_lint_preserves_native_policy(self):
        text = lint.derive()
        compile(text, lint.__file__, 'exec')
        for token in ("manifest['variant']==export.VARIANT", 'assert recovered==original.read_text()',
                      'return status', "manifest['processor_platform_simulator_sha256']==export.MODEL"):
            self.assertIn(token, text)


if __name__ == '__main__': unittest.main()
