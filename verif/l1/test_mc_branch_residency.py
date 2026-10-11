"""Recipe tests; the real descriptor/cache-function miter runs separately."""
import os
from pathlib import Path
import subprocess
import unittest

from prepare_mc_address_payload import assignment
from prepare_mc_branch_residency import OLD, NEW, transform


class BranchResidencyRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['MC_BRANCH_RESIDENCY_PARENT']).read_text()

    def test_exact_local_change(self):
        changed = transform(self.source)
        self.assertEqual(changed.replace(NEW, OLD), self.source)
        self.assertEqual(NEW.split('`else\n')[1].split('`endif')[0], OLD)

    def test_reject_drift_and_reapplication(self):
        for source in (self.source + '\n', transform(self.source)):
            with self.assertRaises(ValueError):
                transform(source)

    def test_request_commit_and_address_equations_unchanged(self):
        changed = transform(self.source)
        for name in ('mem_next_req', 'mem_next_commit', 'mem_next_addr',
                     'mem_next_wstrb', 'mc_prime_offer', 'mc_offer',
                     'mc_prime_accept', 'mc_chain_accept', 'mc_query_pc',
                     'mc_query_seg', 'mc_query_ea', 'mc_query_lin'):
            self.assertEqual(assignment(changed, name), assignment(self.source, name), name)

    def test_bitvector_address_and_helper_bounds(self):
        # Exhaustive arithmetic proof, not a proof of sequential core behavior.
        # All addresses/bases and both four-bit decoded lengths are symbolic.
        query = '''(set-logic QF_BV)
(declare-const cs (_ BitVec 32)) (declare-const eip (_ BitVec 32))
(declare-const pc (_ BitVec 32))
(declare-const u (_ BitVec 4)) (declare-const v (_ BitVec 4))
(declare-const len (_ BitVec 4))
(define-fun off () (_ BitVec 5) (bvadd ((_ zero_extend 1) u) ((_ zero_extend 1) v)))
(define-fun count () (_ BitVec 6) (bvadd ((_ zero_extend 1) off) ((_ zero_extend 2) len)))
(define-fun flin () (_ BitVec 32) (bvadd cs eip))
(define-fun lin () (_ BitVec 32) (bvadd cs pc))
(assert (bvule off (_ bv13 5)))
(assert (= pc (bvadd eip ((_ zero_extend 27) off))))
'''
        identity = '''(or
 (not (= lin (bvadd flin ((_ zero_extend 27) off))))
 (not (= (bvsub (bvadd lin ((_ zero_extend 28) len)) (_ bv1 32))
         (bvsub (bvadd flin ((_ zero_extend 26) count)) (_ bv1 32))))
 (bvugt count (_ bv28 6))
 (bvugt (bvadd ((_ zero_extend 1) ((_ extract 4 0) flin)) count) (_ bv59 6)))'''
        for predicate, expected in (
                (identity, 'unsat'),
                ('(not (= lin flin))', 'sat'),
                ('(not (= ((_ extract 31 5) lin) ((_ extract 31 5) flin)))', 'sat')):
            result = subprocess.run(['/usr/bin/z3', '-in', '-smt2'],
                input=query+'(assert '+predicate+')\n(check-sat)\n', text=True,
                capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
