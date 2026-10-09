import unittest

import cpi_interval as cpi
from prepare_gameplay_window import select_window, frame_bounds


def sample(cycle, retired=None):
    retired = cycle // 2 if retired is None else retired
    fields = dict(cycle=cycle, retires=retired, clocks=cycle,
                  u=retired - cycle // 10, v=cycle // 10, load_wait=0, store_wait=0)
    fields.update({k: '0,0' for k in cpi.ARRAYS})
    fields['state'] = f'{cycle},0'
    return '[VEN-PERF] ' + ' '.join(f'{k}={v}' for k, v in fields.items())


class WindowTests(unittest.TestCase):
    def test_actual_offset_is_preserved(self):
        a, b, d = select_window([sample(i * 100 + 7) for i in range(1, 15)], [12, 13], 100)
        self.assertEqual((a['cycle'], b['cycle'], d['cycle']), (1207, 1307, 100))

    def test_no_best_window_selection(self):
        lines = [sample(i * 100) for i in range(1, 15)]
        a, b, _ = select_window(lines, [2, 3], 100)
        self.assertEqual((a['cycle'], b['cycle']), (200, 300))

    def test_incomplete(self):
        with self.assertRaisesRegex(ValueError, 'not ready'):
            select_window([sample(100), sample(200)], [2, 3], 100)

    def test_missing_and_repeated_samples(self):
        for cycles in ([100, 300, 400], [100, 200, 200], [200, 300, 400]):
            with self.subTest(cycles=cycles), self.assertRaises(ValueError):
                select_window([sample(c) for c in cycles], [1, 2], 100)

    def test_later_reset_rejected(self):
        with self.assertRaises(ValueError):
            select_window([sample(c) for c in (100, 200, 300, 100)], [1, 2], 100)

    def test_invalid_indices(self):
        for indices in ([0, 1], [1, 3], [1], [True, 2]):
            with self.subTest(indices=indices), self.assertRaises(ValueError):
                select_window([sample(100), sample(200)], indices, 100)

    def test_full_counter_invariants(self):
        lines = [sample(100), sample(200).replace('state=200,0', 'state=199,0')]
        with self.assertRaisesRegex(ValueError, 'partition'):
            select_window(lines, [1, 2], 100)

    def test_no_pairing(self):
        lines = [sample(c).replace(f'u={c * 4 // 10}', f'u={c // 2}')
                 .replace(f'v={c // 10}', 'v=0') for c in (100, 200)]
        with self.assertRaisesRegex(ValueError, 'V retirement'):
            select_window(lines, [1, 2], 100)

    def test_unfinished_diagnostic_prefix(self):
        lines = ['tb: unfinished ' + sample(100), sample(200)]
        self.assertEqual(select_window(lines, [1, 2], 100)[2]['cycle'], 100)

    def test_frame_bracket(self):
        lines = ['[ 100] retires=50', '[FBCAP] /frame.ppm 320x200', '[ 200] retires=100']
        self.assertEqual(frame_bounds(lines, '/frame.ppm', 150), [100, 200])
        for endpoint in (99, 201):
            with self.assertRaises(ValueError):
                frame_bounds(lines, '/frame.ppm', endpoint)

    def test_frame_ambiguous_or_unbracketed(self):
        for lines in (['[FBCAP] /frame.ppm x'],
                      ['[ 100] retires=1', '[FBCAP] /frame.ppm x', '[FBCAP] /frame.ppm x', '[ 200] retires=2'],
                      ['[ 100] retires=1', '[FBCAP] /frame.ppm x', '[ 600101] retires=2']):
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                frame_bounds(lines, '/frame.ppm', 150)


if __name__ == '__main__':
    unittest.main()
