import unittest
from pair_interval import samples, report


def row(cycle, paired=0, raw=0, vmem=0):
    return (f'[VEN-PAIR] cycle={cycle} issue=0,{raw+vmem},0,0,0,0,0,0,{paired} '
            f'deny=0,0,0,0,{raw},0,{vmem}\n')


class PairIntervalTest(unittest.TestCase):
    def test_bounds_and_nested_categories(self):
        first, last = samples([row(0), row(100, 20, 5), row(200, 40, 10, 5),
                               row(300, 60, 15, 10)], 50, 250)
        text = report(first, last)
        self.assertIn('Actual interval: 100..200', text)
        self.assertIn('observations: 30', text)
        self.assertIn('RAW dependency: 5', text)
        self.assertIn('V memory operand: 5', text)

    def test_duplicate_sample(self):
        self.assertEqual(samples([row(0), row(0), row(100)])[1][0], 100)

    def test_diagnostic_prefix_and_other_records(self):
        self.assertEqual(samples(['other\n', 'partial' + row(0), row(100)])[0][0], 0)

    def test_zero_observations(self):
        self.assertNotIn('%', report(*samples([row(0), row(100)])))

    def test_bad_records_and_counters(self):
        cases = [
            [row(0)],
            [row(0), '[VEN-PAIR] cycle=1 issue=0 deny=0'],
            [row(0), row(100).replace('deny=0,0', 'deny=1,0')],
            [row(100, 2), row(200, 1)],
            [row(100), row(99)],
            [row(100), row(100, 1)],
            [row(0), row(1, 2)],
            [row(0), row(100, raw=1).replace('deny=0,0,0,0,1', 'deny=0,0,0,0,0')],
        ]
        for records in cases:
            with self.subTest(records=records), self.assertRaises(ValueError):
                samples(records)


if __name__ == '__main__':
    unittest.main()
