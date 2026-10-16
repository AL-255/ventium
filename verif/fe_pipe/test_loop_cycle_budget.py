"""Small parser/accounting tests; do not launch a compiler or simulator."""
import unittest

import analyze_loop_cycle_budget as budget


def rows(clocks=(4, 4, 5, 8, 9, 11, 12, 15)):
    pcs = (0, 16, 20, 16, 20, 16, 20, 24)
    return [dict(n=i, pc=hex(pc), cyc=clock, pipe='V' if i == 1 else 'U', paired=i == 1)
            for i, (pc, clock) in enumerate(zip(pcs, clocks))]


class BudgetTests(unittest.TestCase):
    def test_pair_same_clock_does_not_double_count(self):
        result = budget.partition(rows(), 16)
        self.assertEqual(result['phases'], dict(startup=4, first_traversal=4,
                         repeated_traversals=3, final_traversal_and_exit=4))
        self.assertEqual(result['total_clocks'], 15)
        self.assertEqual((result['u_retirements'], result['v_retirements']), (7, 1))

    def test_conserve_positive_and_negative_delta(self):
        result = budget.compare(rows(), rows((6, 6, 7, 9, 10, 11, 12, 17)), 16)
        self.assertEqual(result['phase_deltas'], dict(startup=2, first_traversal=-1,
                         repeated_traversals=-1, final_traversal_and_exit=2))
        self.assertEqual(sum(result['phase_deltas'].values()), result['total_delta'])

    def test_no_prefix_only_comparison(self):
        with self.assertRaisesRegex(ValueError, 'length'):
            budget.compare(rows(), rows()[:-1], 16)

    def test_reject_pc_divergence_even_in_final_tail(self):
        changed = rows()
        changed[-1]['pc'] = '0x28'
        with self.assertRaisesRegex(ValueError, 'PC streams'):
            budget.compare(rows(), changed, 16)

    def test_reject_bad_sequence_or_clock(self):
        for field, value in (('n', 9), ('cyc', 3), ('cyc', 4.5)):
            with self.subTest(field=field, value=value):
                changed = rows()
                changed[-1][field] = value
                with self.assertRaises(ValueError):
                    budget.partition(changed, 16)

    def test_no_inferred_loop(self):
        with self.assertRaisesRegex(ValueError, 'three visits'):
            budget.partition(rows(), 24)

    def test_fsm_budget_complete(self):
        log = '    state 27        8   53.3%\n    state 28        7   46.7%\n'
        self.assertEqual(budget.fsm_budget(log, 15), {'27': 8, '28': 7})
        with self.assertRaisesRegex(ValueError, 'full trace clocks'):
            budget.fsm_budget(log, 16)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            budget.fsm_budget(log+log, 30)


if __name__ == '__main__':
    unittest.main()
