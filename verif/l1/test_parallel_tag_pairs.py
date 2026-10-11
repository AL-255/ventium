"""Check pair-fixture construction without starting a native build."""
from pathlib import Path
import re
import unittest
from run_parallel_tag_pairs import BASE_OUTPUTS, PAIR_OUTPUTS, fixture


class PairFixture(unittest.TestCase):
    def test_stimulus_and_checks_preserved(self):
        old = Path(__file__).with_name('tb_l1d_pair_store.sv').read_text()
        before, after = re.split(r'  ven_l1d #\(\.L1_SETS\(64\)\) dut \(.*?\);', old, flags=re.S)
        for flat in (False, True):
            new = fixture(old, flat)
            self.assertTrue(new.startswith(before))
            self.assertTrue(new.endswith(after))
            self.assertEqual(new.count('#(.L1_SETS(128))'), 2)
            self.assertEqual(new.count('.c_next_req(c_we)'), 2)
            for name in BASE_OUTPUTS | PAIR_OUTPUTS:
                self.assertEqual(new.count(f'.{name}(shadow_{name})'), 1)
                self.assertIn(f'dut.{name} !== shadow_{name}', new)
            self.assertIn('dc_tag[s*2+w]' if flat else 'dc_tag[s][w]', new)
            self.assertIn('bank<8', new)
            self.assertIn('row<256', new)

    def test_drift_rejected(self):
        old = Path(__file__).with_name('tb_l1d_pair_store.sv').read_text()
        for changed in (old+old, old.replace('.c_pair_ack,', '.missing,', 1), fixture(old, True)):
            with self.assertRaises(ValueError):
                fixture(changed, True)


if __name__ == '__main__':
    unittest.main()
