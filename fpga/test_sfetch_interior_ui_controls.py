import ast
import unittest

import run_sfetch_interior_ui_coremark as cm
import run_sfetch_interior_ui_input as keys
import audit_sfetch_interior_ui_coremark as audit


class Controls(unittest.TestCase):
    def test_keyboard_grading_and_guests_are_unchanged(self):
        text=keys.derive();ast.parse(text)
        for token in ('raw0-positive','raw0-wrong-key',"'--ui-fifo'"):
            self.assertGreater(text.count(token),0)
            self.assertEqual(text.count(token),keys.inspect.getsource(keys.previous.main).count(token))
        self.assertIn("start['directed_model'] == build.cpu.CORE_MODEL",text)
        self.assertIn("start['binding_read_wire'] == 'kb_fifo_rdreq'",text)
        self.assertIn('grade(text,raw)',text)

    def test_crc_exit_and_native_ownership_checks_remain(self):
        text=cm.derive();ast.parse(text)
        for token in ('max_workers=2','rc=child.wait(timeout=600)',
                      'observe_owned_native(', 'actual_wait=True','proc_gone=not proc.exists()',
                      'iterations=10,require_valid_duration=False','reference_crcs=crcs',
                      "{'performance':4771298,'validation':4755366}",
                      'standard_suite=False','score_eligible=False',"assert '[UI-' not in text"):
            self.assertIn(token,text)
        self.assertNotIn("{'performance':4767218,'validation':4753406}",text)

    def test_audit_preserves_crc_and_parent_checks(self):
        text=audit.derive();ast.parse(text)
        self.assertIn('ventium-fprem-sequence.iSZ9BAj4/sfetch-interior-soc-r1',text)
        self.assertNotIn('ventium-fprem-sequence.iSZ9BAj4/v-result-carry-soc-r1',text)
        for token in ("old['ticks'] == result['ticks'] == item['ticks']",
                      "ref['crcs'] == result['crcs'] == item['crcs']",
                      "native['argv'] == argv", 'actual_wait=True',
                      "assert build['directed_model']==integration.cpu.CORE_MODEL",
                      'duration_valid=False,standard_suite=False,physical_board=False'):
            self.assertIn(token,text)


if __name__=='__main__':unittest.main()
