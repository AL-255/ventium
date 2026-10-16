import ast
import unittest
import audit_retained_ui_coremark as audit
import run_retained_ui_coremark as run


class RetainedDisabledControls(unittest.TestCase):
    def test_native_modes_and_ownership_preserved(self):
        text=run.derive();ast.parse(text)
        self.assertIn('ThreadPoolExecutor(max_workers=2)',text)
        self.assertIn("cpu=12 if seed=='performance' else 13",text)
        self.assertIn("Popen(['/usr/bin/taskset','-c',str(cpu)]+argv",text)
        self.assertIn('native_observation.observe_owned_native(',text)
        self.assertIn("assert '[UI-' not in text and '--ui-fifo' not in argv",text)
        self.assertIn("assert result['ticks']=={'performance':4767218,'validation':4753406}[seed]",text)
        for required in ('rc=child.wait(timeout=600)','actual_wait=True',"'proc_gone'",'score_eligible=False'):
            # proc_gone is a keyword in the native receipt, not a JSON literal.
            self.assertIn(required.strip("'"),text)

    def test_audit_cannot_credit_wrong_model_or_ui(self):
        text=audit.derive();ast.parse(text)
        self.assertIn("== runner.MODEL",text)
        self.assertIn("native['affinity'] == [12 if seed=='performance' else 13]",text)
        self.assertIn("assert old['ticks'] == result['ticks'] == item['ticks']",text)
        self.assertIn("assert '[UI-' not in log and '--ui-fifo' not in argv",text)
        self.assertIn('duration_valid=False,standard_suite=False,physical_board=False',text)


if __name__=='__main__':unittest.main()
