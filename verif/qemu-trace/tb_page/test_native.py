"""Expected outcomes retain the separate CS failure instead of hiding it."""
import unittest

import run_native


class Expectations(unittest.TestCase):
    def test_original_and_candidate_failures(self):
        cases = [(kind,reloc,offset) for kind in range(4) for reloc in (0,1)
                 for offset in (4080,4093,4094,4095) if kind != 1 or offset > 4092]
        for variant,count in (('control',12),('candidate',8)):
            self.assertEqual(sum(run_native.expected(k,o,variant) == 135 for k,r,o in cases), count)
        fixed = [(k,r,o) for k,r,o in cases if run_native.expected(k,o,'control') !=
                 run_native.expected(k,o,'candidate')]
        self.assertEqual(fixed, [(3,r,o) for r in (0,1) for o in (4094,4095)])


if __name__ == '__main__':
    unittest.main()
