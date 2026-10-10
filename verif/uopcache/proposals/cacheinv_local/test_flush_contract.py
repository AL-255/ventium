import unittest
from run_flush_contract import grade

GOOD = '''[ICFL] flush
[ICFL] pre set=3 way=1 tag=000f0 ptag=000f0
[ICFL] post set=3 valid=00
[ICFL] fill set=3 way=0 tag=000f0 ptag=000f0
[ICFL] flush_all edges seen: 1
'''


class ContractTests(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(grade(GOOD, 1)[0], dict(flushes=1, nonempty_flushes=1, refilled_flushes=1))

    def test_actual_faults_rejected(self):
        for corrupt in (GOOD.replace('valid=00', 'valid=01'),
                        GOOD.replace('[ICFL] post set=3 valid=00\n', ''),
                        GOOD.replace('[ICFL] fill set=3 way=0 tag=000f0 ptag=000f0\n', ''),
                        GOOD.replace('edges seen: 1', 'edges seen: 2'),
                        GOOD.replace('post set=3', 'post set=4')):
            with self.subTest(corrupt=corrupt), self.assertRaises(AssertionError):
                grade(corrupt, 1)

    def test_refill_before_post_rejected(self):
        rows = GOOD.splitlines()
        rows[2], rows[3] = rows[3], rows[2]
        with self.assertRaises(AssertionError):
            grade('\n'.join(rows), 1)

    def test_vacuity_rejected(self):
        with self.assertRaises(AssertionError):
            grade(GOOD)


if __name__ == '__main__':
    unittest.main()
