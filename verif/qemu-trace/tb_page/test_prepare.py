"""Exact source scope and deterministic page-index counterexamples."""
import difflib
from pathlib import Path
import random
import unittest

import prepare

SOURCE = Path(__file__).resolve().parents[3]/'ventium-refs/07-p5-emulation-harness/build/qemu'/prepare.FILE


class Backport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before=SOURCE.read_text()

    def test_exact_upstream_delta(self):
        after=prepare.transform(self.before)
        changes=[line for line in difflib.ndiff(self.before.splitlines(),after.splitlines())
                 if line.startswith(('- ','+ '))]
        self.assertEqual(changes, ['- '+prepare.OLD,'+ '+prepare.NEW]*2)
        self.assertEqual(after, self.before.replace(prepare.OLD,prepare.NEW))

    def test_refuses_drift_and_reapplication(self):
        for source in (self.before+'\n', self.before.replace(prepare.OLD,prepare.NEW,1),
                       prepare.transform(self.before), self.before.replace('tb_record','tb_rec0rd')):
            with self.assertRaises(ValueError):
                prepare.transform(source)

    def test_second_page_distinctness(self):
        # Independent arithmetic oracle for both bookkeeping functions. Native
        # QEMU execution, not these equations, must qualify the actual backport.
        rng=random.Random(0x3b279f73)
        cases=[(0x2fffe,0x30000),(0x30fff,0x2f000),(0x2fffd,0x2f000),
               (0x2fffd,(1<<64)-1)]
        cases.extend((rng.randrange(1<<32),rng.randrange(1<<20)<<12) for _ in range(4096))
        rejected=0
        for first,second in cases:
            expected=second!=(1<<64)-1 and (first & ~4095)!=(second & ~4095)
            actual=second!=(1<<64)-1 and (first>>12)!=(second>>12)
            self.assertEqual(actual,expected)
            wrong=second!=(1<<64)-1 and (first>>12)!=(first>>12)
            rejected+=wrong!=expected
        self.assertGreater(rejected,4090)


if __name__=='__main__':
    unittest.main()
