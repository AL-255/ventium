import unittest
from pathlib import Path

import audit_kbd_backpressure as audit
import run_kbd_backpressure as runner


class Backpressure(unittest.TestCase):
    def test_matrix(self):
        cases = runner.cases()
        self.assertEqual(len(cases),32)
        self.assertEqual(len(set(cases)),32)
        self.assertEqual(sum(c[0]=='candidate' for c in cases),16)
        self.assertEqual(sum(c[0]=='parent' and c[2] for c in cases),8)

    def test_only_expected_data_loss_is_a_red_witness(self):
        case = ('parent',40000000,1,1,0)
        self.assertTrue(runner.grade(case,1,'FATAL: KBD-BACKPRESSURE-DATA got=11 expected=1c'))
        for code,text in ((0,'KBD-BACKPRESSURE-DATA'),(1,'KBD-BACKPRESSURE-TIMEOUT'),
                          (1,'KBD-BACKPRESSURE-HELD-OWNER'),(124,'KBD-BACKPRESSURE-DATA')):
            self.assertFalse(runner.grade(case,code,text))
        text = 'KBD-BACKPRESSURE-OK hz=40000000 during=1 translate=1 flip=0 frames=2 reads=66 pending=1'
        self.assertTrue(runner.grade(('candidate',40000000,1,1,0),0,text))
        self.assertFalse(runner.grade(('candidate',40000000,1,1,0),1,text))
        self.assertFalse(runner.grade(('candidate',40000000,1,1,0),0,text.replace('pending=1','pending=0')))

    def test_independent_audit_requires_exact_missing_scan(self):
        tb = Path(__file__).with_name('tb_kbd_backpressure.sv').resolve()
        line = next(i for i,s in enumerate(tb.read_text().splitlines(),1)
                    if 'KBD-BACKPRESSURE-DATA' in s)
        text = (f'FATAL: {tb}:{line}: KBD-BACKPRESSURE-DATA got=11 expected=1c\n'
                '       Time: 123 Scope: tb_kbd_backpressure.check_byte\n')
        case = ('parent',40000000,1,1,0)
        audit.check_log(case,1,text,tb)
        for bad in (text.replace('got=11','got=fa'),text.replace('expected=1c','expected=80'),
                    text.replace('check_byte','filler'),text+'extra\n'):
            with self.assertRaises(AssertionError): audit.check_log(case,1,bad,tb)
        with self.assertRaises(AssertionError): audit.check_log(case,0,text,tb)

    def test_independent_audit_checks_completion_location_and_probe(self):
        tb = Path(__file__).with_name('tb_kbd_backpressure.sv').resolve()
        line = next(i for i,s in enumerate(tb.read_text().splitlines(),1) if s.strip()=='$finish;')
        text = ('KBD-BACKPRESSURE-OK hz=40000000 during=1 translate=1 flip=0 frames=2 reads=66 pending=1\n'
                f'{tb}:{line}: $finish called at 10000 (1ps)\n')
        case = ('candidate',40000000,1,1,0)
        audit.check_log(case,0,text,tb)
        for bad in (text.replace('pending=1','pending=0'),text.replace(f':{line}:',f':{line-1}:'),
                    text.replace('frames=2','frames=3')):
            with self.assertRaises(AssertionError): audit.check_log(case,0,bad,tb)


if __name__ == '__main__': unittest.main()
