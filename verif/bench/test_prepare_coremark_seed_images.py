import unittest
from prepare_coremark_seed_images import reference_crcs


class ReferenceTest(unittest.TestCase):
    good = '''CoreMark Size : 666
Iterations : 1400
seedcrc : 0xe9f5
[0]crclist : 0xe714
[0]crcmatrix : 0x1fd7
[0]crcstate : 0x8e3a
[0]crcfinal : 0x1234
ERROR! Must execute for at least 10 secs for a valid result!
Errors detected
'''

    def test_final_comes_from_reference(self):
        self.assertEqual(reference_crcs(self.good, 'performance', 1400)['crcfinal'], '1234')

    def test_wrong_or_incomplete_reference(self):
        for text in [self.good.replace('e714', 'e715'), self.good.replace('1400', '1401'),
                     self.good.replace('666', '2000'), self.good + 'ERROR! Bad data\n',
                     self.good.replace('[0]crcfinal : 0x1234\n', ''),
                     self.good.replace('Errors detected\n', ''),
                     self.good + 'seedcrc : 0xe9f5\n']:
            with self.subTest(text=text), self.assertRaises((AssertionError, ValueError)):
                reference_crcs(text, 'performance', 1400)

    def test_valid_duration_reference(self):
        text = self.good.replace('ERROR! Must execute for at least 10 secs for a valid result!\n', '')
        text = text.replace('Errors detected', 'Correct operation validated.')
        self.assertEqual(reference_crcs(text, 'performance', 1400)['crcfinal'], '1234')


if __name__ == '__main__':
    unittest.main()
