import ast
import unittest
from unittest.mock import patch

import boundary_ui_controls as controls


class Controls(unittest.TestCase):
    def test_only_lineage_policy_and_pins_differ(self):
        for action in controls.TEMPLATES:
            with self.subTest(action=action):
                text = controls.derive(action)
                ast.parse(text)
                restored = text.replace('sfetch-boundary-soc-r1', 'boundary-soc-r1').replace(
                    'boundary-', 'prime-width-').replace('Path(parent_adapter.__file__),', '')
                if action == 'input':
                    restored = restored.replace(
                        "assert start['cycle_cost']['diagnostic_only'] and not start['canonical_gate_passed']",
                        "assert load(soc/'build-wait-closed.json')['passed']")
                if action == 'coremark':
                    restored = restored.replace(
                        "assert started['cycle_cost']['diagnostic_only'] and not started['canonical_gate_passed']",
                        "assert json.loads((soc/'build-wait-closed.json').read_text())['passed']")
                self.assertEqual(restored, controls.parent_adapter.derive(action))

    def test_original_guest_grading_limits_and_expected_clocks(self):
        text = controls.derive('input')
        for token in ('grade(text,raw)', "'--ui-fifo'", 'max_workers=2',
                      'os.sched_getaffinity(0)=={16,17}', 'begin<480',
                      "start['binding_read_wire'] == 'kb_fifo_rdreq'", 'actual_wait=True'):
            self.assertIn(token, text)
        self.assertIs(controls.namespace('input', 'model')['grade'],
                      controls.TEMPLATES['input'][0].previous.grade)
        text = controls.derive('coremark')
        for token in ('max_workers=2', 'rc=child.wait(timeout=600)',
                      'iterations=10,require_valid_duration=False',
                      "{'performance':4771298,'validation':4755366}", "assert '[UI-' not in text"):
            self.assertIn(token, text)
        text = controls.derive('audit-coremark')
        for token in ('ventium-fprem-sequence.iSZ9BAj4/sfetch-boundary-soc-r1',
                      "old['ticks'] == result['ticks'] == item['ticks']",
                      "ref['crcs'] == result['crcs'] == item['crcs']", "native['argv'] == argv"):
            self.assertIn(token, text)

    def test_changed_template_rejected(self):
        with patch.object(controls.build, 'sha', return_value='changed'):
            for action in controls.TEMPLATES:
                with self.subTest(action=action), self.assertRaises(AssertionError):
                    controls.derive(action)

    def test_model_and_cycle_policy_mutants_rejected(self):
        soc = controls.build.ROOT/'boundary-ui-soc-r1'
        cost = dict(diagnostic_only=True, canonical_gate_passed=False)
        start = dict(parent_model=controls.build.PARENT_MODEL, input_parent_model=controls.build.UI_MODEL,
                     directed_model=controls.build.cpu.CORE_MODEL, directed_core='/frozen/core',
                     processor_rtl_changes=[], added_defines=[], pins={}, cycle_cost=cost,
                     changes=[controls.build.ui.PS2], canonical_gate_passed=False)
        done = dict(passed=True, inputs_unchanged=True, native_exit=0, binary_sha256='model')
        records = {'build-started.json': start, 'build-closed.json': done}
        with patch.object(controls.build, 'load', side_effect=lambda p: records[p.name]), \
                patch.object(controls.build, 'sha', return_value='model'), \
                patch.object(controls.build, 'stable', return_value=True), \
                patch.object(controls.build.cpu, 'cycle_cost_diagnostic', return_value=({}, cost)):
            self.assertEqual(controls.selected_model(soc), 'model')
            for record, key, bad in ((start, 'parent_model', 'wrong'),
                                     (start, 'input_parent_model', 'wrong'),
                                     (start, 'directed_model', 'wrong'),
                                     (start, 'processor_rtl_changes', ['changed']),
                                     (start, 'added_defines', ['PAIR_OFF']),
                                     (start, 'changes', []), (start, 'cycle_cost', {}),
                                     (start, 'canonical_gate_passed', True),
                                     (done, 'native_exit', 1), (done, 'passed', False),
                                     (done, 'inputs_unchanged', False),
                                     (done, 'binary_sha256', 'wrong')):
                with self.subTest(key=key), patch.dict(record, {key: bad}), \
                        self.assertRaises(AssertionError):
                    controls.selected_model(soc)
            with patch.object(controls.build, 'stable', return_value=False), \
                    self.assertRaises(AssertionError):
                controls.selected_model(soc)


if __name__ == '__main__':
    unittest.main()
