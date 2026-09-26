import unittest

from l1_fill_profile import summarize


def sample(cycle=10, **changes):
    row = dict(cyc=cycle, req=1, ack=0, we=0, addr=0x2000, cacheable=1,
               state=1, hit=1, xline=0, fill=0x2024, words=3, poison=0,
               bypass=0, flush=0, owner=0x2024)
    row.update(changes)
    return 'VENL1 ' + ' '.join(f'{key}={value:08x}' if key in ('addr', 'fill', 'owner')
                             else f'{key}={value}' for key, value in row.items()) + '\n'


class FillProfileTest(unittest.TestCase):
    def counts(self, **changes):
        return summarize([sample(**changes)])[2]

    def test_other_set_hit(self):
        self.assertEqual(self.counts()['potential_other_set_hit'], 1)
        self.assertEqual(self.counts(hit=0)['potential_other_set_hit'], 0)
        # Different tags but the same set are deliberately excluded.
        self.assertEqual(self.counts(addr=0x3024)['potential_other_set_hit'], 0)

    def test_wrapped_completed_words(self):
        self.assertEqual(self.counts(addr=0x2000, fill=0x201c, owner=0x201c,
                                     words=2)['potential_arrived_fill_word'], 1)
        # The requested word is the next beat, not already in the array.
        self.assertEqual(self.counts(addr=0x2004, fill=0x201c, owner=0x201c,
                                     words=2)['potential_arrived_fill_word'], 0)

    def test_owner_unaligned_and_poison(self):
        base = dict(addr=0x2028)
        self.assertEqual(self.counts(**base)['potential_arrived_fill_word'], 1)
        for changes in (dict(owner=0x2028), dict(addr=0x2029), dict(poison=1),
                        dict(words=0), dict(words=1)):
            self.assertEqual(self.counts(**(base | changes))['potential_arrived_fill_word'], 0)

    def test_qualification(self):
        for key in ('ack', 'we', 'bypass', 'flush', 'xline'):
            self.assertEqual(self.counts(**{key: 1})['potential_other_set_hit'], 0)
        for key in ('req', 'cacheable'):
            self.assertEqual(self.counts(**{key: 0})['potential_other_set_hit'], 0)
        self.assertEqual(self.counts(state=0)['fill_residency'], 0)
        # Poison of an unrelated fill does not invalidate a resident other-set hit.
        self.assertEqual(self.counts(poison=1)['potential_other_set_hit'], 1)

    def test_consecutive_observation_accounting(self):
        first, last, counts = summarize(['noise\n', sample(10), 'prefix ' + sample(11)])
        self.assertEqual((first, last, counts['observations']), (10, 11, 2))
        for cycle in (9, 10, 12):
            with self.assertRaises(ValueError):
                summarize([sample(10), sample(cycle)])

    def test_malformed_or_absent(self):
        for lines in ([], ['VENL1 cyc=1\n'], [sample(req=2)], [sample(words=8)],
                      [sample(addr=-1)], [sample().strip() + ' ack=0\n']):
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                summarize(lines)


if __name__ == '__main__':
    unittest.main()
