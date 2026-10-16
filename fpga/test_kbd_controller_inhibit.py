import unittest
import run_kbd_controller_inhibit as run


class ControllerInhibitTests(unittest.TestCase):
    def test_matrix_includes_shared_reset_and_stop_edges(self):
        cases=run.cases()
        self.assertEqual(len(cases),106)
        self.assertEqual(len(set(cases)),106)
        self.assertEqual(sum(c[0]=='candidate' for c in cases),104)
        for hz in (3125000,40000000):
            for phase in (23,24,25):
                for reset in (0,1):
                    self.assertIn(('candidate',hz,phase,reset),cases)

    def test_red_witness_is_not_a_correctness_pass(self):
        red='FATAL: fixture.sv:1: KBD-CONTROLLER-EARLY-READY hz=40000000 phase=20\n'
        self.assertTrue(run.grade(('parent',40000000,20,0),1,red))
        self.assertFalse(run.grade(('candidate',40000000,20,0),1,red))
        self.assertFalse(run.grade(('parent',40000000,20,0),1,'bounded controller test timeout'))
        for phase,retry in ((23,1),(24,1),(25,0)):
            text=f'KBD-CONTROLLER-OK hz=40000000 phase={phase} reset=0 retry={retry} irq1=1\n'
            self.assertTrue(run.grade(('candidate',40000000,phase,0),0,text))
            self.assertFalse(run.grade(('candidate',40000000,phase,1),0,text))


if __name__=='__main__':unittest.main()
