import ast
import unittest

import audit_v_result_gameplay_window as audit


class GameplayWindow(unittest.TestCase):
    def test_native_and_counter_checks_retained(self):
        text=audit.derive(); ast.parse(text)
        for marker in ("closed['native_exit']==0", "==MODEL", "=={14}",
                       "==native['argv']==inputs['command'][3:]", "not inputs['snapshots']",
                       "window.cpi.validate_profile(delta,is_delta=True)",
                       "48146083", "37609117", "10536966", '100000000',
                       'pixels(ppm)==pixels(png)', 'whole_timedemo=False',
                       'current_candidate_gameplay_ipc=None', 'physical_fpga=False'):
            self.assertIn(marker,text)
        self.assertIn('v-result-carry-soc-r1',text)
        self.assertIn('quake-cold-v-result-carry-oct16.1',text)
        self.assertNotIn('decode-bus-soc',text)


if __name__=='__main__': unittest.main()
