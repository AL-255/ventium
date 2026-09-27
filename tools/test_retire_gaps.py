import unittest

from retire_gaps import summarize


def record(n, pc, cycle):
    return f"VTM n={n} 00a7:{pc:08x} fl=0 cyc={cycle}\n"


class RetireGapsTest(unittest.TestCase):
    def test_paired_groups_and_initial_exclusion(self):
        rows = ["unrelated diagnostic\n", record(10, 1, 100), record(11, 2, 100),
                record(12, 3, 104), record(13, 4, 104), record(14, 5, 106)]
        records, counted, cycles, stats = summarize(rows)
        self.assertEqual((records, counted, cycles), (5, 3, 6))
        self.assertEqual(stats[("00a7:00000003", "00a7:00000004")], [4, 1, 4])
        self.assertEqual(sum(row[0] for row in stats.values()), 6)

    def test_repeated_pc(self):
        result = summarize([record(1, 1, 3), record(2, 1, 5), record(3, 1, 10)])
        self.assertEqual(result[3][("00a7:00000001",)], [7, 2, 5])

    def test_invalid_inputs(self):
        for rows in [[], [record(1, 1, 1)], [record(1, 1, 1), record(3, 2, 2)],
                     [record(1, 1, 2), record(2, 2, 1)], ["VTM n=1 missing timestamp\n"]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                summarize(rows)


if __name__ == "__main__":
    unittest.main()
