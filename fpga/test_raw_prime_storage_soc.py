import copy
import inspect
import unittest

import build_raw_prime_storage_soc as build


class Transfer(unittest.TestCase):
    def test_exact_single_delta(self):
        name = build.recipe.FILE
        old = (build.PARENT/'source'/name).read_bytes()
        new = (build.CORE/'candidate'/name).read_bytes()
        self.assertTrue(build.check_delta(name, old, new))
        with self.assertRaises(AssertionError):
            build.check_delta(name, old, new+b'\n')
        self.assertFalse(build.check_delta('rtl/core/core.sv', b'same', b'same'))
        with self.assertRaises(AssertionError):
            build.check_delta('rtl/core/core.sv', b'old', b'new')

    def test_audit_does_not_promote_failures(self):
        audit = build.load(build.ROOT/'raw-prime-storage-core-checks-r1/parent-equivalence-audit.json')
        build.check_equivalence(audit)
        for key in ('legacy_aggregate_gate_passed','canonical_gate_passed','standard_suite','hardware_acceptance'):
            mutated = copy.deepcopy(audit); mutated[key] = True
            with self.subTest(key=key), self.assertRaises(AssertionError):
                build.check_equivalence(mutated)
        for key in ('stream_pairs','func_records','cycle_records','actual_v_retirements'):
            mutated = copy.deepcopy(audit); mutated['totals'][key] -= 1
            with self.subTest(key=key), self.assertRaises(AssertionError):
                build.check_equivalence(mutated)

    def test_host_and_uv_mode_are_preserved(self):
        source = inspect.getsource(build.prepare)
        for token in ('shutil.copyfile(old_host, host)', 'transfer.check_definitions',
                      "binding_read_wire='kb_fifo_rdreq'", 'inherited_cycle_cost=',
                      'added_defines=[]', "sha(source/parent_build.ui.PS2)", 'assert stable(pins)'):
            self.assertIn(token, source)
        self.assertIn('return transfer.base.build(root)', inspect.getsource(build.main))


if __name__ == '__main__': unittest.main()
