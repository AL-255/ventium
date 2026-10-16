import unittest
from audit_coremark_clock_trial import paired_lower_bound


class Witness(unittest.TestCase):
    def test_prior_v_retirements_not_counted(self):
        # Huge V history but no new pairing: must not become a new UV pass.
        samples=[dict(total_retirements=900_000_000,primary_retirements_before=500_000_000,
                      primary_retirements_after=500_000_010),
                 dict(total_retirements=910_000_000,primary_retirements_after=510_000_010)]
        self.assertEqual(paired_lower_bound(samples,500_000_000),-10)
    def test_current_v_and_read_uncertainty(self):
        samples=[dict(total_retirements=900_000_000,primary_retirements_before=500_000_000),
                 dict(total_retirements=930_000_000,primary_retirements_after=520_000_010)]
        self.assertEqual(paired_lower_bound(samples,499_000_000),9_999_990)
        del samples[0]['primary_retirements_before']
        self.assertEqual(paired_lower_bound(samples,499_000_000),8_999_990)
    def test_counter_resets_rejected(self):
        with self.assertRaises(ValueError):
            paired_lower_bound([dict(total_retirements=1000,primary_retirements_before=900),
                                dict(total_retirements=1,primary_retirements_after=901)],900)


if __name__=='__main__': unittest.main()
