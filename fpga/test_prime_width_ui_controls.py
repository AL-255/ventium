import ast
import unittest
from unittest.mock import patch

import prime_width_ui_controls as controls


class Controls(unittest.TestCase):
    def test_only_lineage_and_pin_changes(self):
        for action, (template, _) in controls.TEMPLATES.items():
            with self.subTest(action=action):
                text = controls.derive(action)
                ast.parse(text)
                restored = text.replace('prime-width-', 'sfetch-interior-').replace(
                    'Path(template.__file__),Path(previous.__file__),',
                    'Path(previous.__file__),')
                self.assertEqual(restored, template.derive())

    def test_keyboard_grading_and_pairing_preserved(self):
        text = controls.derive('input')
        for token in ('raw0-positive', 'raw0-wrong-key', "'--ui-fifo'", 'grade(text,raw)',
                      "start['binding_read_wire'] == 'kb_fifo_rdreq'",
                      "start['directed_model'] == build.cpu.CORE_MODEL",
                      'actual_wait=True', 'max_workers=2', 'os.sched_getaffinity(0)=={16,17}'):
            self.assertIn(token, text)
        scope = controls.namespace('input', 'unused')
        self.assertIs(scope['grade'], controls.input_template.previous.grade)

    def test_crc_duration_ownership_and_parent_preserved(self):
        text = controls.derive('coremark')
        for token in ('max_workers=2', 'rc=child.wait(timeout=600)', 'observe_owned_native(',
                      'actual_wait=True', 'iterations=10,require_valid_duration=False',
                      "{'performance':4771298,'validation':4755366}",
                      'standard_suite=False', 'score_eligible=False', "assert '[UI-' not in text"):
            self.assertIn(token, text)
        audit = controls.derive('audit-coremark')
        for token in ('ventium-fprem-sequence.iSZ9BAj4/prime-width-soc-r1',
                      "old['ticks'] == result['ticks'] == item['ticks']",
                      "ref['crcs'] == result['crcs'] == item['crcs']",
                      "native['argv'] == argv", 'duration_valid=False,standard_suite=False,physical_board=False'):
            self.assertIn(token, audit)

    def test_wrong_or_changed_template_rejected(self):
        with self.assertRaises(KeyError):
            controls.derive('not-a-control')
        with patch.object(controls.build, 'sha', return_value='changed'):
            for action in controls.TEMPLATES:
                with self.subTest(action=action), self.assertRaises(AssertionError):
                    controls.derive(action)

    def test_exact_parent_injected(self):
        for action in controls.TEMPLATES:
            scope = controls.namespace(action, 'new-model-hash')
            self.assertEqual(scope['MODEL'], 'new-model-hash')
            self.assertEqual(scope['runner'].MODEL, 'new-model-hash')
            self.assertEqual(scope['runner'].PARENT_MODEL, controls.build.PARENT_MODEL)
            self.assertIs(scope['build'], controls.build)
            self.assertIs(scope['integration'], controls.build)

    def test_unqualified_or_different_model_rejected(self):
        soc = controls.build.ROOT/'prime-width-ui-soc-r1'
        start = dict(parent_model=controls.build.PARENT_MODEL,
                     input_parent_model=controls.build.UI_MODEL,
                     directed_model=controls.build.cpu.CORE_MODEL,
                     processor_rtl_changes=[], added_defines=[], pins={})
        done = dict(passed=True, inputs_unchanged=True, native_exit=0, binary_sha256='model')
        waiting = dict(passed=True)
        records = {'build-started.json': start, 'build-closed.json': done,
                   'build-wait-closed.json': waiting}
        with patch.object(controls.build, 'load', side_effect=lambda p: records[p.name]), \
                patch.object(controls.build, 'sha', return_value='model'), \
                patch.object(controls.build, 'stable', return_value=True):
            self.assertEqual(controls.selected_model(soc), 'model')
            for record, key, bad in ((start, 'parent_model', 'wrong-parent'),
                                     (start, 'input_parent_model', 'wrong-input'),
                                     (start, 'directed_model', 'wrong-core'),
                                     (start, 'processor_rtl_changes', ['unexpected.sv']),
                                     (start, 'added_defines', ['PAIRING_OFF']),
                                     (done, 'native_exit', 1), (done, 'passed', False),
                                     (done, 'inputs_unchanged', False),
                                     (done, 'binary_sha256', 'wrong-binary'),
                                     (waiting, 'passed', False)):
                with self.subTest(key=key), patch.dict(record, {key: bad}), \
                        self.assertRaises(AssertionError):
                    controls.selected_model(soc)
            with patch.object(controls.build, 'stable', return_value=False), \
                    self.assertRaises(AssertionError):
                controls.selected_model(soc)


if __name__ == '__main__':
    unittest.main()
