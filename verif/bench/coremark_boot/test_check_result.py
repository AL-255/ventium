import unittest
from check_result import check, DURATION_ERROR

CRCS = ['e9f5', 'e714', '1fd7', '8e3a', 'fcaf']


def fixture(ticks=5096514, iterations=10):
    end = 0x100000000 - 16 + ticks
    valid = ticks >= 400000000
    return '\n'.join([
        'CoreMark Size    : 666', f'Total ticks      : {ticks}',
        f'Total time (secs): {ticks//40000000}', f'Iterations       : {iterations}',
        'seedcrc          : 0xe9f5', '[0]crclist       : 0xe714',
        '[0]crcmatrix     : 0x1fd7', '[0]crcstate      : 0x8e3a',
        '[0]crcfinal      : 0xfcaf',
        'Correct operation validated.' if valid else DURATION_ERROR+'\nErrors detected',
        f'PORT-TSC start=00000000:fffffff0 stop={end>>32:08x}:{end&0xffffffff:08x}',
        f'PORT-TSC delta={ticks>>32:08x}:{ticks&0xffffffff:08x}', 'PORT-END', ''])


class ResultTest(unittest.TestCase):
    def runcheck(self, text, valid=False):
        return check(text, reference_crcs=CRCS, iterations=10, require_valid_duration=valid)

    def test_short_is_not_score(self):
        self.assertFalse(self.runcheck(fixture())['duration_valid'])

    def test_counter_low_word_rollover(self):
        self.assertEqual(self.runcheck(fixture())['ticks'], 5096514)

    def test_duration_valid_console_is_not_board_acceptance(self):
        self.assertFalse(self.runcheck(fixture(400000001), True)['physical_board_qualified'])

    def test_negative_controls(self):
        original = fixture()
        bad = [original.replace('0xe714', '0x0000'),
               original.replace('Iterations       : 10', 'Iterations       : 11'),
               original.replace('CoreMark Size    : 666', 'CoreMark Size    : 667'),
               original.replace('Total ticks      : 5096514', 'Total ticks      : 5096513'),
               original.replace('Total time (secs): 0', 'Total time (secs): 1'),
               original.replace('PORT-END', ''), original+'PORT-END\n',
               original+'ERROR! bad data\n', original.replace(DURATION_ERROR, ''),
               original+'[0]crcfinal      : 0xfcaf\n',
               original.replace('004dc442', '004dc443'),
               original.replace('stop=00000001:', 'stop=00000002:')]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(ValueError): self.runcheck(text)

    def test_no_short_pass(self):
        with self.assertRaises(ValueError): self.runcheck(fixture(), True)

    def test_full_tick_overflow_rejected(self):
        with self.assertRaises(ValueError): self.runcheck(fixture(1 << 32), True)


if __name__ == '__main__': unittest.main()
