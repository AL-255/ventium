"""Exact source scope and all two-state exponent/normalization inputs."""
import os
from pathlib import Path
import subprocess
import unittest
from prepare_div_exp_width import ANCHOR, HELPER, NEW, OLD, proof, transform


class DivideExponentWidth(unittest.TestCase):
    def source(self): return Path(os.environ['SRT_DIV_EXP_PARENT']).read_text()

    def test_exact_scope(self):
        source = self.source(); new = transform(source)
        self.assertEqual(new.replace(HELPER, '').replace(NEW, OLD), source)
        self.assertEqual(new.count(HELPER), 1)
        self.assertEqual(new.count(NEW), 1)
        self.assertEqual(new.count(ANCHOR), 1)
        self.assertIn('logic signed [31:0]  ua, ub;', new)
        self.assertEqual(new[new.index('        // ---- DIVIDE iterate'):],
                         source[source.index('        // ---- DIVIDE iterate'):])

    def test_drift_rejected(self):
        source = self.source()
        for bad in (source+'\n', transform(source)):
            with self.assertRaises(ValueError): transform(bad)

    def test_exhaustive_symbolic_and_mutants(self):
        for mutation, expected in ((None,'unsat'),('zero-bias','sat'),('too-narrow','sat'),('unsigned','sat')):
            with self.subTest(mutation=mutation):
                run = subprocess.run(['/usr/bin/z3','-in','-smt2'], input=proof(mutation),
                    text=True,capture_output=True,timeout=15)
                self.assertEqual((run.returncode,run.stdout.strip(),run.stderr),(0,expected,''))


if __name__ == '__main__': unittest.main()
