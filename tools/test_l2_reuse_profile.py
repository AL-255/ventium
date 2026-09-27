import unittest

from l2_reuse_profile import fill_lines, reuse_counts


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


if __name__ == '__main__':
    unittest.main()
