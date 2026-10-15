"""Fail-closed checks for the independent wait-profile grader; no model runs."""
from copy import deepcopy
import unittest

import audit_cycle_memory_profile as audit

LOG = '''tb: --l1-axi selected default --quiesce=200000
tb: retired 2 instructions in 18 clocks (bus: 0 reads, 0 writes)
  retires 2 (U=1 pairedV=1)
[L1DPERF] fill cycles=10 backing-wait=2 backing-ack=8
'''


class Checks(unittest.TestCase):
    def test_native_counts(self):
        self.assertEqual(audit.parse_log(LOG), dict(records=2, clocks=18,
            u=1, v=1, fill_cycles=10, backing_wait=2, backing_ack=8))

    def test_reject_bad_or_ambiguous_logs(self):
        for bad in (LOG + LOG, LOG.replace('pairedV=1', 'pairedV=0'),
                    LOG.replace('backing-ack=8', 'backing-ack=0'),
                    LOG.replace('fill cycles=10', 'fill cycles=11'),
                    LOG.replace('--l1-axi selected', 'direct memory'),
                    LOG + '%Fatal: failure', LOG.replace('tb: retired', 'missing')):
            with self.subTest(log=bad), self.assertRaises(AssertionError):
                audit.parse_log(bad)

    def test_architecture_and_actual_pairing(self):
        cycle = audit.tracefmt.Trace(dict(mode='cycle', x87=False), [
            dict(n=0, pc='0x00001000', cyc=18, pipe='U', paired=False),
            dict(n=1, pc='0x00001002', cyc=18, pipe='V', paired=True)])
        func = audit.tracefmt.Trace(dict(mode='func', x87=False), [
            dict.fromkeys(audit.tracefmt.GPR_KEYS + audit.tracefmt.SEG_KEYS + ['eflags'], 0)
            for _ in range(2)])
        for i, f in enumerate(func.records):
            f.update(n=i, pc=cycle.records[i]['pc'])
        stats = audit.parse_log(LOG)
        audit.validate_traces(cycle, func, stats)
        mutations = [
            lambda c, f: f.records[0].pop('eax'),
            lambda c, f: f.records[1].update(pc='0x00001004'),
            lambda c, f: c.records[1].update(cyc=19),
            lambda c, f: c.records[1].update(paired=False),
            lambda c, f: c.records[0].update(pipe='V', paired=True),
            lambda c, f: f.hdr.update(x87=True),
        ]
        for mutate in mutations:
            c, f = deepcopy(cycle), deepcopy(func)
            mutate(c, f)
            with self.assertRaises(AssertionError):
                audit.validate_traces(c, f, stats)


if __name__ == '__main__':
    unittest.main()
