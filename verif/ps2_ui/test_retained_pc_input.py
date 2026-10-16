"""Grader negatives are synthetic parser tests, never RTL acceptance."""
import unittest

import run_retained_pc_input as r


def sample(raw):
    text='[UI-READY] pid=1 half=1667 idle=4000 framing=lf_ascii\n'
    text+='[BOARD_AXI] real RTL profile=1 slots=16 B-delay=20 R-first=21 gap=1\n'
    text+=f'UI-PROBE-READY raw={raw}\n'
    for ident,op,count in ((1,'key',6),(2,'key',3),(3,'capture',0)):
        text+=f'[UI-QUEUED] id={ident} cycle=100 op={op} bytes={count} queued=1\n'
    for index,value in enumerate(r.RAW):
        ident=1 if index<6 else 2;local=index+1 if ident==1 else index-5;total=6 if ident==1 else 3
        text+=f'[UI-WIRE-BYTE] id={ident} cycle={200+index} index={local} total={total} raw={value:02x}\n'
        if local==total:text+=f'[UI-WIRE-COMPLETE] id={ident} cycle={200+index} bytes={total} ui_success=not_asserted\n'
    for value in r.EXPECTED[raw]:
        text+=f'[UI-GUEST-READ] cycle=300 id_context=1 value={value:02x} correlation=unproven ui_success=not_asserted\n'
    text+=f'UI-PROBE-PASS raw={raw}\n'
    text+='[UI-CAPTURE-UNAVAILABLE] id=3 cycle=400 path=none pixels=raw ui_success=not_asserted\n'
    text+='[VEN-PERF] cycle=500 retires=100 clocks=499 u=95 v=5\n'
    text+='[UI-END] cycle=500 pending=0 owned=0 failed=0\n'
    return text


class Grader(unittest.TestCase):
    def test_both_streams(self):
        for raw in (0,1):
            result=r.grade(sample(raw),raw)
            self.assertEqual(result['guest_reads'],r.EXPECTED[raw])
            self.assertFalse(result['ui_success_asserted'])
            self.assertIsNone(result['gameplay_ipc'])

    def test_lost_duplicated_or_wrong_reads(self):
        s=sample(0);line=next(x for x in s.splitlines(True) if '[UI-GUEST-READ]' in x)
        for bad in (s.replace(line,''),s+line,s.replace('value=1d','value=ff')):
            with self.assertRaises(AssertionError):r.grade(bad,0)

    def test_refuses_loss_prefix_pairing_or_guest_failure(self):
        s=sample(0)
        for before,after in (('raw=f0','raw=ff'),('pending=0','pending=1'),('v=5','v=0'),
                             ('UI-PROBE-PASS','UI-PROBE-FAIL'),('id=2 cycle=208 bytes=3','id=2 cycle=208 bytes=2'),
                             ('half=1667','half=24')):
            self.assertIn(before,s)
            with self.assertRaises(AssertionError):r.grade(s.replace(before,after),0)
        with self.assertRaises(AssertionError):r.grade(s+'[UI-ERROR] wrong_fifo_byte\n',0)


if __name__=='__main__':unittest.main()
