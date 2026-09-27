import unittest

from load_chain_profile import pairs, summarize


def observation(cycle, n, pc=0x1000, addr=0x2000, *, ack=1, we=0, state=28):
    return ({'cyc': cycle, 'n': n, 'eip': pc, 'state': state, 'ack': ack},
            {'cyc': cycle, 'req': 1, 'ack': ack, 'we': we, 'addr': addr,
             'cacheable': 1, 'hit': 1, 'xline': 0, 'flush': 0})


class LoadChainTests(unittest.TestCase):
    def test_two_loads_with_capture_gap(self):
        rows = [observation(0, 0), observation(1, 1, pc=0x1002, ack=0),
                observation(2, 1, pc=0x1002, addr=0x2004), observation(3, 2)]
        counts, gaps = summarize(rows, 28, 1)
        self.assertEqual(counts['single_read_completion_groups'], 2)
        self.assertEqual(counts['also_cacheable_resident_non_crossing'], 1)
        self.assertEqual(gaps, {2: 1})
        self.assertEqual(counts['retired_instructions'], 2)

    def test_intervening_retirement_breaks_chain(self):
        rows = [observation(0, 0), observation(1, 1, state=5),
                observation(2, 2, pc=0x1002), observation(3, 3)]
        counts, _ = summarize(rows, 28, 1)
        self.assertEqual(counts['single_read_completion_groups'], 2)
        self.assertEqual(counts['adjacent_single_read_pairs'], 0)

    def test_pair_is_not_single_load(self):
        rows = [observation(0, 0), observation(1, 2, pc=0x1002), observation(2, 3)]
        counts, _ = summarize(rows, 28, 1)
        self.assertEqual(counts['single_read_completion_groups'], 1)
        self.assertEqual(counts['paired_read_completion_groups'], 1)
        self.assertEqual(counts['all_read_completion_groups'], 2)
        self.assertEqual(counts['adjacent_single_read_pairs'], 0)

    def test_different_page_or_nonsequential_pc_rejected(self):
        for pc, addr in ((0x1002, 0x3000), (0x1020, 0x2004), (0x1000, 0x2004)):
            rows = [observation(0, 0), observation(1, 1, pc=pc, addr=addr), observation(2, 2)]
            counts, gaps = summarize(rows, 28, 1)
            self.assertEqual(counts['adjacent_single_read_pairs'], 1)
            self.assertFalse(gaps)

    def test_write_is_not_read(self):
        rows = [observation(0, 0), observation(1, 1, pc=0x1002, we=1), observation(2, 2)]
        counts, _ = summarize(rows, 28, 1)
        self.assertEqual(counts['single_read_completion_groups'], 1)

    def test_registered_retire_dpi_lag(self):
        rows = [observation(0, 0), observation(1, 0, ack=0),
                observation(2, 1, pc=0x1002, addr=0x2004),
                observation(3, 1, ack=0), observation(4, 2, ack=0)]
        counts, gaps = summarize(rows, 28, 2)
        self.assertEqual(counts['single_read_completion_groups'], 2)
        self.assertEqual(gaps, {2: 1})
        wrong, _ = summarize(rows, 28, 1)
        self.assertEqual(wrong['single_read_completion_groups'], 0)
        with self.assertRaises(ValueError):
            summarize(rows, 28, 0)

    def test_join_rejects_missing_duplicate_gap_and_counter_reset(self):
        def lines(c, n):
            return [f'VENSTATE cyc={c} n={n} state=28 eip=00001000 fx=0 step=0 ack=1 addr=00002000 we=0 rsp=0\n',
                    f'VENL1 cyc={c} req=1 ack=1 we=0 addr=00002000 cacheable=1 state=0 hit=1 xline=0 fill=00002000 words=0 poison=0 bypass=0 flush=0 owner=00002000\n']
        self.assertEqual(len(list(pairs(lines(0, 0)+lines(1, 1)))), 2)
        for bad in (lines(0, 0)[:1], lines(0, 0)[1:], lines(0, 0)+lines(0, 0),
                    lines(0, 0)+lines(2, 1), lines(0, 1)+lines(1, 0),
                    lines(0, 0)[:1]+lines(1, 1)[1:]):
            with self.assertRaises(ValueError):
                list(pairs(bad))


if __name__ == '__main__':
    unittest.main()
