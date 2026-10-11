"""Exact edits and protocol-cofactor proof, not whole-RTL equivalence."""
import os
from pathlib import Path
import subprocess
import unittest
from prepare_bus_cancel_payload import EDITS, transform, tail


def proof(mutation=None):
    # Translation is an arbitrary pure function. A kept request must present
    # its exact original input and result, regardless of the TLB contents.
    text = '''(set-logic QF_UFBV)
(declare-fun xlate ((_ BitVec 32) Bool) (_ BitVec 32))
(declare-const address (_ BitVec 32))
(declare-const linear (_ BitVec 32))
(declare-const data (_ BitVec 32))
(declare-const strobes (_ BitVec 4))
(declare-const write Bool)
(declare-const request Bool)
(declare-const translatable Bool)
(declare-const paging Bool)
(declare-const physical Bool)
(declare-const miss Bool)
(declare-const pending Bool)
(declare-const permission Bool)
(declare-const syncfault Bool)
(declare-const stosblock Bool)
(declare-const movsblock Bool)
(declare-const async_hold Bool)
(declare-const a20 Bool)
(declare-const is_data Bool)
(define-fun addr0 () (_ BitVec 32) (ite translatable linear address))
(define-fun paged () Bool (and paging (not physical)))
(define-fun fault () Bool (or miss pending permission))
(define-fun pgcancel () Bool (and paged fault))
(define-fun accesscancel () Bool (or syncfault stosblock movsblock))
(define-fun old_pre () Bool (and request (not pgcancel) (not stosblock) (not movsblock)))
(define-fun old_req () Bool (and request (not pgcancel) (not accesscancel) (not async_hold)))
(define-fun old_addr1 () (_ BitVec 32)
 (ite pgcancel #x00000000 (ite (and paged request) (xlate addr0 is_data) addr0)))
(define-fun old_addr2 () (_ BitVec 32) (ite accesscancel #x00000000 old_addr1))
(define-fun old_addr () (_ BitVec 32)
 (ite (and request (not pgcancel) (not accesscancel) (not a20))
      (bvand old_addr2 #xffefffff) old_addr2))
(define-fun old_we () Bool (and write (not pgcancel) (not accesscancel)))
(define-fun old_data () (_ BitVec 32) (ite (or pgcancel accesscancel) #x00000000 data))
(define-fun old_strb () (_ BitVec 4) (ite (or pgcancel accesscancel) #x0 strobes))
(define-fun new_pgcancel () Bool (and paged fault))
(define-fun new_pre () Bool (and request (not new_pgcancel) (not stosblock) (not movsblock)))
(define-fun new_req () Bool (and request (not new_pgcancel) (not accesscancel) (not async_hold)))
(define-fun new_addr1 () (_ BitVec 32) (ite (and paged request) (xlate addr0 is_data) addr0))
(define-fun new_addr () (_ BitVec 32) (ite a20 new_addr1 (bvand new_addr1 #xffefffff)))
(assert (or (not (= old_pre new_pre)) (not (= old_req new_req))
 (and new_req (or (not (= old_addr new_addr)) (not (= old_we write))
                 (not (= old_data data)) (not (= old_strb strobes))))))
(check-sat)
'''
    if mutation == 'permission':
        text = text.replace('(define-fun new_pgcancel () Bool (and paged fault))',
                            '(define-fun new_pgcancel () Bool (and paged (or miss pending)))')
    elif mutation == 'a20':
        text = text.replace('(ite a20 new_addr1 (bvand new_addr1 #xffefffff))', 'new_addr1')
    elif mutation == 'pre':
        text = text.replace('(define-fun new_pre () Bool (and request (not new_pgcancel) (not stosblock) (not movsblock)))',
                            '(define-fun new_pre () Bool (and request (not new_pgcancel) (not accesscancel)))')
    return text


class BusCancelPayload(unittest.TestCase):
    def test_reversible_scope(self):
        old = Path(os.environ['BUS_CANCEL_PARENT']).read_text()
        new = transform(old)
        for before, after in reversed(EDITS):
            self.assertEqual(new.count(after), 1)
            new = new.replace(after, before)
        self.assertEqual(new, old)
        self.assertIn('mem_req_pre_sq = bd_req', tail(old))

    def test_drift_and_reapplication(self):
        source = Path(os.environ['BUS_CANCEL_PARENT']).read_text()
        for bad in (source+'\n', transform(source)):
            with self.assertRaises(ValueError): transform(bad)

    def test_all_binary_request_cofactors(self):
        for mutation, expected in ((None,'unsat'),('permission','sat'),('a20','sat'),('pre','sat')):
            with self.subTest(mutation=mutation):
                run = subprocess.run(['/usr/bin/z3','-in','-smt2'],input=proof(mutation),
                    text=True,capture_output=True,timeout=15)
                self.assertEqual((run.returncode,run.stdout.strip(),run.stderr),(0,expected,''))


if __name__ == '__main__': unittest.main()
