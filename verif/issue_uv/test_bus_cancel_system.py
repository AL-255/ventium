"""Host contracts for precise-fault witnesses; native coverage is separate."""
from types import SimpleNamespace
import unittest
from run_bus_cancel_system import CASES, WITNESSES, A20, A20CMD, witness


class SystemContracts(unittest.TestCase):
    def test_named_original_cases_are_distinct_and_bounded(self):
        self.assertEqual(len(CASES), 9)
        self.assertEqual(len({row[1] for row in CASES}), 9)
        self.assertEqual({row[1] for row in CASES if row[4]}, {'pxc04e', 'pxc04f'})
        self.assertTrue(all(0 < row[3] <= 10000 for row in CASES))

    def test_every_precise_fault_witness_rejects_one_bit_corruption(self):
        for name, fields in WITNESSES.items():
            record = {key: hex(value) for key, value in fields.items()}
            witness(name, SimpleNamespace(records=[record]))
            for key, value in fields.items():
                with self.subTest(case=name, field=key), self.assertRaises(AssertionError):
                    witness(name, SimpleNamespace(records=[dict(record, **{key: hex(value ^ 1)})]))

    def test_a20_witness_requires_exactly_one_complete_result(self):
        for name, expected in (('a20test', A20), ('a20cmdtest', A20CMD)):
            trace = SimpleNamespace(records=[{}])
            witness(name, trace, expected+'\n')
            for bad in ('', expected+expected, expected[:-1]):
                with self.subTest(case=name, log=bad), self.assertRaises(AssertionError):
                    witness(name, trace, bad)


if __name__ == '__main__':
    unittest.main()
