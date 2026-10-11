"""Recipe checks and all-64-bit two-state arithmetic proof through Z3."""
import os
from pathlib import Path
import subprocess
import unittest
from prepare_rem_clz_tree import OLD, NEW, transform


def proof(mutant=None):
    # Old loop: first set bit scanning from bit 63 down. This recursive form
    # checks high bits last while constructing the expression, so the highest
    # set bit becomes the outermost selected result.
    old = '(_ bv64 7)'
    for i in range(64):
        old = f'(ite (= ((_ extract {i} {i}) x) #b1) (_ bv{63-i} 7) {old})'
    lines = ['(set-logic QF_BV)', '(declare-const x (_ BitVec 64))',
             '(define-fun old () (_ BitVec 7) '+old+')']
    word, width, bits = 'x', 64, []
    for stage in range(5, 0, -1):
        half = width//2
        hi = f'((_ extract {width-1} {half}) {word})'
        lo = f'((_ extract {half-1} 0) {word})'
        pred = f'(= {hi} (_ bv0 {half}))'
        lines.append(f'(define-fun n{stage} () (_ BitVec 1) (ite {pred} #b1 #b0))')
        # Deliberately wrong upper/lower half selection is a required witness.
        if mutant == 'half' and stage == 5:
            hi, lo = lo, hi
        lines.append(f'(define-fun w{half} () (_ BitVec {half}) (ite {pred} {lo} {hi}))')
        bits.append(f'n{stage}')
        word, width = f'w{half}', half
    bits.append(f'(bvnot ((_ extract 1 1) {word}))')
    # Build the exact seven-bit concatenation {0,n[5:0]}.
    count = '#b0'
    for bit in bits:
        count = f'(concat {count} {bit})'
    balanced = f'(ite (= x (_ bv0 64)) (_ bv64 7) {count})'
    if mutant == 'zero': balanced = count
    return '\n'.join(lines+[f'(assert (not (= old {balanced})))','(check-sat)'])+'\n'


class RemainderClzTree(unittest.TestCase):
    def test_reversible(self):
        source = Path(os.environ['SRT_CLZ_PARENT']).read_text()
        self.assertEqual(transform(source).replace(NEW, OLD), source)

    def test_drift(self):
        source = Path(os.environ['SRT_CLZ_PARENT']).read_text()
        for changed in (source+'\n', transform(source)):
            with self.assertRaises(ValueError): transform(changed)

    def test_all_inputs_and_negative_controls(self):
        for mutation, expected in ((None,'unsat'),('zero','sat'),('half','sat')):
            with self.subTest(mutation=mutation):
                p = subprocess.run(['/usr/bin/z3','-in','-smt2'],input=proof(mutation),
                                   text=True,capture_output=True,timeout=15)
                self.assertEqual((p.returncode,p.stdout.strip(),p.stderr),(0,expected,''))


if __name__ == '__main__': unittest.main()
