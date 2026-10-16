"""Guard exception fixtures, one-op delivery site, and native ownership checks."""
import inspect
import copy
from types import SimpleNamespace
import unittest
import run_strict_mf_waiters as run
import audit_strict_mf_waiters as audit


class Waiters(unittest.TestCase):
    def test_immediate_producer_and_saved_eip(self):
        self.assertEqual(len(run.WAITERS),29)
        for row in run.vectors():
            for waiter in run.WAITERS:
                source=run.source(row,waiter)
                arm=source.split('.macro ARM_PENDING_MF\n')[1].split('.endm')[0]
                self.assertEqual(arm.splitlines()[-1].strip(),'fprem1' if row['op'] else 'fprem')
                self.assertNotIn('fnstsw',arm)
                self.assertNotIn('fwait',arm)
                self.assertEqual(source.count('    CHECK_REMAINDER\n'),2)
                self.assertEqual(source.count('cmpl    EXPECT_EIP, %eax'),2)
                self.assertIn('CHKL    EVENT_SEQ, 0x007F',source)
                self.assertIn('CHKL    CASES, 4, 0x43',source)
                # This is a guest fault/retry, never handler instruction skip.
                self.assertNotIn('addl $',source[source.index('mf_entry:'):source.index('ud_entry:')])
                body=source.split('case_mf_fld1:\n')[1].split('case_mf_after:')[0]
                insns=[s.strip() for s in body.splitlines() if s.strip() and not s.startswith('.')]
                self.assertEqual(insns[0],run.WAITERS[waiter].splitlines()[0])

    def test_native_guards_and_checks_preserved(self):
        before=inspect.getsource(run.base.main);after=run.derive()
        a,b='    def native(', '    begin, rows, errors'
        self.assertIn(before[before.index(a):before.index(b)],after)
        self.assertIn("faults == ['7', '7', '16', '7', '16']",after)
        self.assertIn("if r['model'] in ('parent','candidate')",after)
        self.assertIn('len(rows) == 2*len(WAITERS)*3*3',after)
        self.assertIn('nonstrict negative-control inventory changed',after)
        self.assertIn('assert arow[key] == brow[key]',after)
        self.assertIn("'--cycle-func', '--l1-axi', '--x87'",after)

    def test_sign_restoration_and_operand_setup(self):
        pos,neg=run.vectors()
        for row in (pos,neg):
            body=run.source(row,'fabs').split('case_mf_fld1:\n')[1].split('case_mf_after:')[0]
            self.assertEqual('    fchs\n' in body,bool(row['values'][0][0]&0x8000))
        for row in (pos,neg):
            arm=run.source(row,'fmul32').split('.macro ARM_PENDING_MF\n')[1].split('.endm')[0]
            self.assertIn('movl $0x3f800000, 0x20d0',arm)

    def test_independent_grade_rejects_bad_guest_exit_and_fault_order(self):
        # In-memory grading fixture only; no architectural trace is emitted.
        record=dict(eax='0x42',ebx='0x3',ecx='0x2',esi='0x4',edi='0x42')
        record.update({k:'0x0' for k in ('fctrl','fstat','ftag',
                       *('st'+str(i) for i in range(8)))})
        trace=SimpleNamespace(records=[record],mode='func',x87=True,hdr={'sys':True})
        log='--l1-axi selected\npairedV=4\n  clocks 100\n'+''.join(
            '[FAULT] vec='+str(v)+'\n' for v in (7,7,16,7,16))
        log+='[L1DPERF] fill cycles=90 backing-wait=40 backing-ack=3\n'
        self.assertTrue(audit.grade(log,trace,133)['passed'])
        self.assertFalse(audit.grade(log,trace,0)['passed'])
        self.assertFalse(audit.grade(log.replace('vec=7','vec=16',1),trace,133)['passed'])
        record['esi']='0x3'
        self.assertFalse(audit.grade(log,trace,133)['passed'])

    def test_independent_grade_requires_x87_and_actual_pairing_backend(self):
        record={k:'0x0' for k in ('eax','ebx','ecx','esi','edi','fctrl','fstat','ftag',
                                *('st'+str(i) for i in range(8)))}
        trace=SimpleNamespace(records=[record],mode='func',x87=True,hdr={'sys':True})
        log='--l1-axi selected\npairedV=4\n  clocks 100\n'
        log+='[L1DPERF] fill cycles=90 backing-wait=40 backing-ack=3\n'
        for invalid in (log.replace('pairedV=4','pairedV=0'),
                        log.replace('backing-ack=3','backing-ack=0'),
                        log+'%Error\n'):
            with self.assertRaises(AssertionError):audit.grade(invalid,trace,133)
        trace.x87=False
        with self.assertRaises(AssertionError):audit.grade(log,trace,133)

    def test_delivery_records_distinguish_faults_from_retry(self):
        def record(pc,esp=0x9000,sw=0x3200,cr0=0x33):
            return {k:hex(v) for k,v in dict(pc=pc,esp=esp,fstat=sw,cr0=cr0).items()}
        rows=[record(0x100,0x8ff4,0xb290),record(0x200),record(0x100),record(0x102),
              record(0x110,0x8ff4,0xb290,0x3b),record(0x300),
              record(0x110,0x8ff4,0xb290),record(0x200),record(0x110),record(0x112)]
        targets={'case_mf_fld1':0x100,'case_both_fld1':0x110}
        handlers={'mf_entry':0x200,'nm_entry':0x300}
        audit.check_delivery_records(rows,targets,handlers,2)
        # Reject skipped handlers, a changed exception, wrong priority,
        # premature stack mutation, an uncleared retry, and an extra execution.
        for index,field,value in ((1,'pc','0x102'),(0,'fstat','0xb288'),
                                  (4,'cr0','0x33'),(0,'esp','0x9000'),
                                  (8,'fstat','0xb290')):
            bad=copy.deepcopy(rows);bad[index][field]=value
            with self.assertRaises(AssertionError):
                audit.check_delivery_records(bad,targets,handlers,2)
        with self.assertRaises(AssertionError):
            audit.check_delivery_records(rows+[record(0x110)],targets,handlers,2)


if __name__=='__main__':unittest.main()
