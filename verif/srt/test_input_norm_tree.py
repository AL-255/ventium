"""Exact edit contracts and all two-state input CLZ equivalence in Z3.

The proof models the search, not the complete RTL engine. Native engine A/B
and four-state helper checks are separate obligations.
"""
import os
from pathlib import Path
import subprocess
import unittest
from prepare_input_norm_tree import ANCHOR, EDITS, HELPER, transform


def proof(mutation=None):
    old = '(_ bv0 6)'
    for bit in range(64):
        old = f'(ite (= ((_ extract {bit} {bit}) x) #b1) (_ bv{63-bit} 6) {old})'
    lines = ['(set-logic QF_BV)', '(declare-const x (_ BitVec 64))',
             '(define-fun old () (_ BitVec 6) ' + old + ')']
    word, width, bits = 'x', 64, []
    for stage in range(5, 0, -1):
        half = width // 2
        hi = f'((_ extract {width-1} {half}) {word})'
        lo = f'((_ extract {half-1} 0) {word})'
        nz = f'(not (= {hi} (_ bv0 {half})))'
        lines.append(f'(define-fun n{stage} () (_ BitVec 1) (ite {nz} #b0 #b1))')
        if mutation == 'half' and stage == 5:
            hi, lo = lo, hi
        lines.append(f'(define-fun w{half} () (_ BitVec {half}) (ite {nz} {hi} {lo}))')
        bits.append(f'n{stage}')
        word, width = f'w{half}', half
    bits.append(f'(bvnot ((_ extract 1 1) {word}))')
    tree = bits[0]
    for bit in bits[1:]:
        tree = f'(concat {tree} {bit})'
    result = f'(ite (= x (_ bv0 64)) (_ bv0 6) {tree})'
    if mutation == 'zero':
        result = tree
    return '\n'.join(lines + [f'(assert (not (= old {result})))', '(check-sat)']) + '\n'


class InputNormalizationTree(unittest.TestCase):
    def test_exact_reversible_edit(self):
        source = Path(os.environ['SRT_INPUT_PARENT']).read_text()
        new = transform(source)
        self.assertEqual(new.count(HELPER), 1)
        original = new.replace(HELPER, '')
        for before, after in EDITS:
            self.assertNotIn(before, new)
            self.assertEqual(new.count(after), 1)
            original = original.replace(after, before)
        self.assertEqual(original, source)
        self.assertEqual(new.count(ANCHOR), 1)

    def test_refuse_drift_and_reapplication(self):
        source = Path(os.environ['SRT_INPUT_PARENT']).read_text()
        for value in (source + '\n', transform(source)):
            with self.assertRaises(ValueError):
                transform(value)

    def test_all_binary_inputs_and_bad_controls(self):
        for mutation, expected in ((None, 'unsat'), ('zero', 'sat'), ('half', 'sat')):
            with self.subTest(mutation=mutation):
                run = subprocess.run(['/usr/bin/z3', '-in', '-smt2'],
                    input=proof(mutation), text=True, capture_output=True, timeout=15)
                self.assertEqual((run.returncode, run.stdout.strip(), run.stderr),
                                 (0, expected, ''))


if __name__ == '__main__':
    unittest.main()
