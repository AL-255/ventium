import ast
import copy
import inspect
import unittest
from unittest.mock import patch

import build_boundary_ui_soc as build
import test_next_ready_ui_transfer as transfer


class Compose(transfer.Compose):
    def test_only_exact_controller_delta(self):
        with patch.object(transfer, 'build', build):
            super().test_only_exact_controller_delta()

    def test_identical_qualified_host_and_binding(self):
        with patch.object(transfer, 'build', build):
            super().test_identical_qualified_host_and_binding()

    def test_original_cycle_policy_not_silently_replaced(self):
        text = build.prepare_source()
        ast.parse(text)
        for token in ("assert changed == [ui.PS2]", 'processor_rtl_changes=[]',
                      "assert before['cycle_cost'] == cost_record",
                      'cycle_cost=cost_record', "parent_coremark_cost=controls['measurements']",
                      'cpu.previous.check_definitions', 'assert stable(pins)'):
            self.assertIn(token, text)
        self.assertIn('return cpu.build(root)', inspect.getsource(build.main))
        self.assertIn("assert not checked['canonical_gate_passed']", build.cpu.build_source())

    def test_exact_parent_costs_retained_and_mutants_rejected(self):
        controls = build.load(build.PARENT/'coremark-r1/audit.json')
        build.check_control_costs(controls)
        for field, bad in (('parent_ticks', 4771298), ('candidate_ticks', 4767218),
                           ('added_clocks', 0), ('actual_v', 0), ('crcs', []),
                           ('duration_valid', True)):
            changed = copy.deepcopy(controls)
            changed['measurements'][0][field] = bad
            with self.subTest(field=field), self.assertRaises(AssertionError):
                build.check_control_costs(changed)
        for field, bad in (('model', 'wrong'), ('passed', False), ('no_oom', False),
                           ('all_children_reaped', False), ('duration_valid', True),
                           ('standard_suite', True), ('physical_board', True),
                           ('gameplay_ipc', 0.5)):
            with self.subTest(field=field), patch.dict(controls, {field: bad}), \
                    self.assertRaises(AssertionError):
                build.check_control_costs(controls)


if __name__ == '__main__':
    unittest.main()
