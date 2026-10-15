"""Host negative controls for the non-differential finite-CS grader."""
import copy
from types import SimpleNamespace
import unittest

import run_finite_cs_rtl as gate


class FiniteCSGrading(unittest.TestCase):
    def setUp(self):
        self.trace = SimpleNamespace(hdr={'producer': 'rtl'}, x87=False, mode='cycle', records=[
            dict(n=i, pc=hex(0xf0000+i), cyc=10+i, paired=i == 90, pipe='V' if i == 90 else 'U')
            for i in range(110)])
        self.stdout = ('[FAULT] vec=13 err=00000000 pc=0002fffd state=2 v86=0 depth=0\n'
                       '[L1DPERF] fill cycles=30 backing-wait=20 backing-ack=10\n')
        self.stderr = 'tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 110 retired in 1234 clocks\n'

    def grade(self, trace=None, stdout=None, stderr=None, code=133):
        return gate.grade(self.trace if trace is None else trace,
            self.stdout if stdout is None else stdout, self.stderr if stderr is None else stderr,
            code, 'cycle', 0x2fffd, 0xf0000+90)

    def test_original_eight_cases(self):
        self.assertEqual(gate.CASES, [(2, r, o) for r in (0, 1) for o in (4080, 4093, 4094, 4095)])

    def test_success_and_failed_native_exit(self):
        self.assertEqual(self.grade()['paired_v'], 1)
        with self.assertRaises(AssertionError):
            self.grade(code=135)

    def test_fault_contract(self):
        for text in (self.stdout.replace('vec=13', 'vec=14'),
                     self.stdout.replace('err=00000000', 'err=00000001'),
                     self.stdout.replace('pc=0002fffd', 'pc=0002fffe'),
                     self.stdout+self.stdout.splitlines()[0]+'\n'):
            with self.subTest(text=text), self.assertRaises((AssertionError, ValueError)):
                self.grade(stdout=text)

    def test_partial_commit_or_lost_pairing_rejected(self):
        for mutate in (lambda t: t.records[20].update(pc='0x2fffd'),
                       lambda t: t.records[90].update(paired=False),
                       lambda t: t.records[90].update(pipe='U'),
                       lambda t: t.records[20].update(n=23)):
            trace = copy.deepcopy(self.trace); mutate(trace)
            with self.assertRaises(AssertionError):
                self.grade(trace=trace)

    def test_closed_backend_required(self):
        for stream, text in (('stderr', self.stderr.replace('110 retired', '109 retired')),
                             ('stderr', self.stderr+'FATAL\n'),
                             ('stdout', self.stdout.replace('backing-ack=10', 'backing-ack=0'))):
            with self.subTest(stream=stream), self.assertRaises(AssertionError):
                self.grade(**{stream: text})


if __name__ == '__main__':
    unittest.main()
