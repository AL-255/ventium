"""Receipt-schema regression and fail-closed controls; no subprocess launches."""
from copy import deepcopy
import unittest

from resume_mc_pair_srt_checks import check_replay


class ReplayReceipt(unittest.TestCase):
    def setUp(self):
        self.receipt = dict(same_input_regression_passed=True, pins_unchanged=True,
            errors=[], rows=[dict(case=str(i), passed=True, records=1) for i in range(108)],
            records=108, canonical_gate_passed=False)

    def test_actual_producer_schema(self):
        self.assertNotIn('passed', self.receipt)
        check_replay(self.receipt)

    def test_reject_missing_replay_field(self):
        del self.receipt['same_input_regression_passed']
        self.receipt['passed'] = True
        with self.assertRaises(KeyError):
            check_replay(self.receipt)

    def test_reject_incomplete_failed_changed_or_waived_receipt(self):
        for change in (dict(same_input_regression_passed=False), dict(pins_unchanged=False),
                       dict(errors=['failure']), dict(rows=self.receipt['rows'][:-1]),
                       dict(records=107), dict(canonical_gate_passed=True)):
            with self.subTest(change=change):
                receipt = deepcopy(self.receipt)
                receipt.update(change)
                with self.assertRaises(AssertionError):
                    check_replay(receipt)


if __name__ == '__main__':
    unittest.main()
