import ast
import unittest

import run_kbd_mmio as run
import audit_kbd_mmio as audit


class KeyboardMMIO(unittest.TestCase):
    def test_matrix_has_skew_and_old_positive_controls(self):
        cases = run.cases()
        self.assertEqual(len(cases), 24)
        self.assertEqual(len(set(cases)), 24)
        self.assertEqual(sum(c[0] == 'parent' and c[3] == 1 for c in cases), 6)
        self.assertEqual(sum(c[0] == 'parent' and c[3] == 0 for c in cases), 6)
        for case in cases:
            label,hz,order,inhibit = case
            positive = f'KBD-MMIO-OK hz={hz} order={order} inhibit={inhibit} submits=2 irq1=1\n'
            negative = f'FATAL: fixture.sv:1: KBD-MMIO-EARLY-READY hz={hz} order={order}\n'
            red = label == 'parent' and bool(inhibit)
            self.assertEqual(run.grade(case, 0, positive), not red)
            self.assertEqual(run.grade(case, 1, negative), red)
            self.assertFalse(run.grade(case, 1, 'bounded MMIO test timeout'))

    def test_native_guards_and_actual_management_preserved(self):
        text = run.derive()
        ast.parse(text)
        for token in ('(MGMT,MGMT_SHA)', "files={'mgmt.v':MGMT", "'mgmt.v','controller.v'",
                      'sorted(os.sched_getaffinity(0))==[12,13]', 'max_workers=2',
                      'child.wait(timeout=30)', 'child.kill();child.wait()',
                      'debug_mmio_tested=True,full_wrapper=False', 'physical_fpga=False',
                      'standard_suite=False', "f'+order={phase}',f'+inhibit={reset}'"):
            self.assertIn(token, text)
        self.assertNotIn('tb_kbd_controller_inhibit.sv', text)

    def test_audit_retains_native_evidence_and_positive_controls(self):
        text = audit.derive()
        ast.parse(text)
        for token in ("red=label=='parent' and reset==1", 'original_endpoint_positive_controls=6',
                      'original_endpoint_red_witnesses=6', "row['passed'] and row['waited']",
                      "row['native_exit']==int(red)", "run.sha(image)==row['image_sha256']",
                      "InvocationID=start['invocation']", 'management_sha256=run.MGMT_SHA',
                      'debug_mmio_tested=True,full_wrapper=False'):
            self.assertIn(token,text)


if __name__ == '__main__':
    unittest.main()
