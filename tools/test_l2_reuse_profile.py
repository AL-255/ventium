import unittest
from io import StringIO

from l2_reuse_profile import fill_lines, miss_event_lines, reuse_counts


class L2ReuseProfileTest(unittest.TestCase):
    def test_only_new_cacheable_fills_and_64_byte_lines(self):
        rows = [dict(state=s, bypass=b, fill=a) for s, b, a in (
            (1, 0, 0), (1, 0, 0), (0, 0, 0), (1, 0, 63),
            (1, 0, 64), (0, 0, 0), (1, 1, 128), (0, 0, 0),
            (1, 0, 127))]
        self.assertEqual(list(fill_lines(rows)), [0, 1])

    def test_lru_and_capacity(self):
        # 1 KiB, four-way has four sets; five lines mapped to one set evict
        # the oldest, whereas 2 KiB has eight sets and retains it.
        stream = [0, 4, 8, 12, 16, 0]
        result = reuse_counts(stream, (1, 2))
        self.assertEqual((result[1]['hits'], result[1]['misses']), (0, 6))
        self.assertEqual((result[2]['hits'], result[2]['misses']), (1, 5))

    def test_empty_and_bad_capacity(self):
        self.assertEqual(reuse_counts([], (1,))[1]['misses'], 0)
        with self.assertRaises(ValueError):
            reuse_counts([], (0,))

    def test_state_miss_events_exclude_unissued_next_lookups(self):
        header = 'cycle\tphysical_line\tset\tkind\tcore_eip\n'
        rows = ('11\t00001000\t0\t0\t1234\n'
                '12\t00001020\t1\t1\t1238\n'
                '13\t00002000\t0\t2\t123c\n'
                '14\t00001040\t2\t1\t1240\n')
        self.assertEqual(list(miss_event_lines(StringIO(header + rows))),
                         [0x1000 >> 6, 0x1020 >> 6, 0x1040 >> 6])
        counts = reuse_counts(miss_event_lines(StringIO(header + rows)), (1,))
        self.assertEqual((counts[1]['hits'], counts[1]['misses']), (1, 2))

    def test_state_miss_events_reject_bad_schema_or_order(self):
        header = 'cycle\tphysical_line\tset\tkind\tcore_eip\n'
        for text in ('cycle\tphysical_line\tkind\n',
                     header + '10\t1001\t0\t1\t10\n',
                     header + '10\t1000\t1\t1\t10\n',
                     header + '10\t1000\t0\t3\t10\n',
                     header + '10\t1000\t0\t1\t10\n10\t1020\t1\t1\t11\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                list(miss_event_lines(StringIO(text)))


if __name__ == '__main__':
    unittest.main()
