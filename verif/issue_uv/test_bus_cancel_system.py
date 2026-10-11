"""Host contracts for precise-fault witnesses; native coverage is separate."""
from pathlib import Path
from types import SimpleNamespace
import unittest
from run_bus_cancel_system import CASES, WITNESSES, A20, A20CMD, witness, a20_no_reset, fetch_fault_witness


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

    def test_cycle_records_do_not_claim_architectural_fields(self):
        trace = SimpleNamespace(records=[dict(n=0, pc='0x1000', cyc=1, pipe='U', paired=False)])
        witness('pxfrag', trace, architectural=False)
        with self.assertRaises(KeyError):
            witness('pxfrag', trace, architectural=True)

    def test_a20_fixture_changes_only_reset_deassertion(self):
        source = Path(__file__).resolve().parents[1]/'sys/tests/mabench/a20test.S'
        original = source.read_text()
        changed = a20_no_reset(original)
        before, after = original.splitlines(), changed.splitlines()
        different = [(old, new) for old, new in zip(before, after) if old != new]
        self.assertEqual(len(before), len(after))
        self.assertEqual(len(different), 1)
        self.assertIn('movb $0x02,%al', different[0][0])
        self.assertIn('movb $0x03,%al', different[0][1])
        with self.assertRaises(AssertionError):
            a20_no_reset(changed)

    def test_fetch_extent_checks_fault_count_identity_and_error_code(self):
        good = '\n'.join('[FAULT] vec=13 err=00000000 pc='+pc for pc in
                         ('0000003b', '0000003c', '0000003f', '00000040'))+'\n'
        fetch_fault_witness(good)
        for bad in (good+good, good.replace('0000003c', '0000003e'),
                    good.replace('err=00000000', 'err=00000001'), good.split('\n', 1)[1]):
            with self.assertRaises(AssertionError):
                fetch_fault_witness(bad)


if __name__ == '__main__':
    unittest.main()
