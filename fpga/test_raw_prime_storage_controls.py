import ast
import unittest
from unittest.mock import patch

import raw_prime_storage_controls as controls


class Controls(unittest.TestCase):
    def test_only_lineage_and_pin_changes(self):
        for action in controls.TEMPLATES:
            with self.subTest(action=action):
                text = controls.derive(action)
                ast.parse(text)
                text = text.replace("'raw-prime-storage-soc-r1'", "'boundary-ui-soc-r1'")
                text = text.replace('ventium-raw-prime-storage-cm10-', 'ventium-boundary-ui-cm10-')
                text = text.replace('.parent_build.UI_MODEL', '.UI_MODEL').replace('.CORE_MODEL', '.cpu.CORE_MODEL')
                text = text.replace("['inherited_cycle_cost']", "['cycle_cost']")
                text = text.replace('Path(parent_controls.__file__),', '')
                if action == 'audit-coremark':
                    text = text.replace('[integration.recipe.FILE]', '[]')
                    text = text.replace('ventium-fprem-sequence.iSZ9BAj4/boundary-ui-soc-r1',
                                        'ventium-fprem-sequence.iSZ9BAj4/sfetch-boundary-soc-r1')
                    text = text.replace("parent/'coremark-ui-disabled-r1/", "parent/'coremark-r1/")
                else:
                    text = text.replace('[build.recipe.FILE]', '[]')
                self.assertEqual(text, controls.parent_controls.derive(action))

    def test_pins_drift_is_rejected(self):
        with patch.object(controls.build, 'sha', return_value='drift'):
            for action in controls.TEMPLATES:
                with self.assertRaises(AssertionError): controls.derive(action)

    def test_real_guest_grading_and_limits_remain(self):
        text = controls.derive('coremark')
        for token in ("{'performance':4771298,'validation':4755366}",
                      'require_valid_duration=False', 'max_workers=2',
                      'rc=child.wait(timeout=600)', "assert '[UI-' not in text"):
            self.assertIn(token, text)
        text = controls.derive('input')
        for token in ('grade(text,raw)', 'begin<480', 'os.sched_getaffinity(0)=={16,17}',
                      'max_workers=2', 'actual_wait=True'):
            self.assertIn(token, text)
        self.assertIs(controls.namespace('input', 'model')['grade'],
                      controls.TEMPLATES['input'][0].previous.grade)


if __name__ == '__main__': unittest.main()
