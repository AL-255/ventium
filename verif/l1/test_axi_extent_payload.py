"""Recipe, arithmetic identity and falsification checks, not FPGA acceptance."""
import os
from pathlib import Path
import subprocess
import unittest
from prepare_axi_extent_payload import OLD, NEW, PAIR_OLD, PAIR_NEW, block, transform


class ExtentPayload(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['AXI_EXTENT_PARENT']).read_text()

    def test_exact_delta(self):
        changed = transform(self.source)
        self.assertEqual(changed.replace(NEW,OLD).replace(PAIR_NEW,PAIR_OLD), self.source)
        self.assertEqual(block(changed).replace(NEW,OLD).replace(PAIR_NEW,PAIR_OLD), block(self.source))

    def test_refuse_source_drift(self):
        for bad in (self.source+'\n', transform(self.source)):
            with self.assertRaises(ValueError): transform(bad)

    def test_all_word_addresses_formal(self):
        # Exact unsigned word arithmetic in OLD/NEW and PAIR_OLD/PAIR_NEW.
        # Address, spill and mask are unconstrained. Narrow reads are unchanged.
        prefix = '''(set-logic QF_BV)
(declare-const a (_ BitVec 32))
(declare-const spill Bool)
(declare-const mask (_ BitVec 32))
(define-fun old () (_ BitVec 32)
  (bvadd (concat ((_ extract 31 2) a) #b00) (ite spill #x00000007 #x00000003)))
(define-fun new () (_ BitVec 32)
  (ite spill (concat (bvadd ((_ extract 31 2) a) (_ bv1 30)) #b11)
             (concat ((_ extract 31 2) a) #b11)))
'''
        tests = (
            ('full-word-extent', '(not (= old new))', 'unsat'),
            ('arbitrary-address-mask', '(not (= (bvand old (bvnot mask)) (bvand new (bvnot mask))))', 'unsat'),
            # A design that forgets the second word must be falsifiable.
            ('missing-spill-mutant', '(not (= old (concat ((_ extract 31 2) a) #b11)))', 'sat'),
            # Precomputing the increment with 29 bits corrupts upper carry.
            ('narrow-increment-mutant', '(and spill (not (= old (concat #b0 (bvadd ((_ extract 30 2) a) (_ bv1 29)) #b11))))', 'sat'),
        )
        for name, predicate, expected in tests:
            with self.subTest(name=name):
                p = subprocess.run(['/usr/bin/z3','-in','-smt2'], input=prefix+'(assert '+predicate+')\n(check-sat)\n',
                                   capture_output=True, text=True, timeout=10)
                self.assertEqual(p.returncode,0,p.stderr)
                self.assertEqual(p.stdout.strip(),expected,p.stdout)


if __name__ == '__main__': unittest.main()
