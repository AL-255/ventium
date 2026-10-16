import unittest

from audit_cycle_accounting import account


def row(n, cyc, pipe='U', pc=None):
    return dict(n=n, cyc=cyc, pipe=pipe, pc=hex(0x100+n if pc is None else pc))


class Accounting(unittest.TestCase):
    def test_paired_cycle_is_counted_once(self):
        d = account([row(0,3), row(1,3,'V'), row(2,6), row(3,7)])
        self.assertEqual((d['total_cycles'], d['initial_no_retirement_cycles'],
                          d['active_retirement_cycles'], d['later_no_retirement_cycles']), (7,2,3,2))
        self.assertEqual(d['accounting_sum'], 7)
        self.assertEqual(d['retirements_per_active_cycle'], {1:2,2:1})
        self.assertEqual(d['pipe_counts'], {'U':3,'V':1})

    def test_repeated_edges_do_not_drop_cold_cycles(self):
        rows = [row(i, 50+i, pc=0x100+i%2) for i in range(10)]
        d = account(rows)
        self.assertEqual(d['total_cycles'], 59)
        self.assertEqual(d['initial_no_retirement_cycles'], 49)
        self.assertEqual(d['repeated_backward_edges'][0]['intervals'],
                         [dict(cycles=2,instructions=2,count=3,cpi=1.0)])

    def test_invalid_counter_and_record_order_rejected(self):
        for rows in ([row(0,2),row(1,1)], [row(0,1),row(2,2)], [row(0,0)], [], [row(0,1,'X')]):
            with self.assertRaises(AssertionError):
                account(rows)

    def test_entire_idle_gap_is_accounted(self):
        d = account([row(0,1),row(1,71)])
        self.assertEqual(d['later_no_retirement_cycles'], 69)
        self.assertEqual(d['accounting_sum'], 71)


if __name__ == '__main__':
    unittest.main()
