"""Binary protocol cofactor proof, with deliberately failing mutations.

This does not prove downstream equivalence when no request is issued, nor
four-state equivalence for unknown admission controls. Do not call it a core
gate or use it to bypass the fragment/system/cache regressions.
"""
import os
from pathlib import Path
import subprocess
import unittest

from prepare_fragment_read_payload import OLD, NEW, blocks, transform


def proof(mutation=None):
    text = '''(set-logic QF_BV)
(declare-const state (_ BitVec 4))
(declare-const translatable Bool)
(declare-const request Bool)
(declare-const write Bool)
(declare-const paging Bool)
(declare-const miss Bool)
(declare-const pending Bool)
(declare-const permission Bool)
(declare-const syncfault Bool)
(declare-const stosblock Bool)
(declare-const movsblock Bool)
(declare-const async_hold Bool)
(declare-const active Bool)
(declare-const abort Bool)
(declare-const fragment_write Bool)
(declare-const phase (_ BitVec 2))
(declare-const linear_low (_ BitVec 12))
(declare-const size (_ BitVec 4))
(declare-const strobes (_ BitVec 4))
(declare-const saved_strobes (_ BitVec 4))
(declare-const first (_ BitVec 3))
; 1 WALK, 2 SMI_SAVE, 3 RSM, 4 LOAD, 5 LOAD2, 6 STORE; other states abstracted.
(define-fun physical () Bool (or (= state #x1) (= state #x2) (= state #x3)))
(define-fun state_ok () Bool (and translatable (not physical)
 (not (= state #x4)) (not (= state #x5)) (not (= state #x6))))
(define-fun pgcancel () Bool (and paging (not physical) (or miss pending permission)))
(define-fun pre () Bool (and request (not pgcancel) (not stosblock) (not movsblock)))
(define-fun bd_req () Bool (and pre (not syncfault) (not async_hold)))
(define-fun highest () (_ BitVec 13)
 (ite (= ((_ extract 3 3) strobes) #b1) (_ bv3 13)
  (ite (= ((_ extract 2 2) strobes) #b1) (_ bv2 13)
   (ite (= ((_ extract 1 1) strobes) #b1) (_ bv1 13) (_ bv0 13)))))
(define-fun cross () Bool (ite write
 (bvugt (bvadd ((_ zero_extend 1) linear_low) highest) (_ bv4095 13))
 (bvugt (bvadd ((_ zero_extend 1) linear_low) ((_ zero_extend 9) size)) (_ bv4096 13))))
(define-fun start () Bool (and state_ok pre paging (or (not active) abort) cross
 (not miss) (not permission) (not syncfault) (not pending)))
(define-fun shape () Bool (and state_ok paging (or (not active) abort) cross))
(define-fun engaged () Bool (and active (not (= state #x1)) (not abort)))
(define-fun probe () Bool (and engaged fragment_write (= phase #b00)))
(define-fun shift () Bool (and engaged fragment_write (= phase #b10)))
(define-fun mask_a () Bool (and engaged fragment_write (= phase #b01)))
(define-fun read_second () Bool (and engaged (not fragment_write) (= phase #b01)))
(define-fun read_first_q () Bool (and engaged (not fragment_write) (= phase #b00)))
(define-fun old_first () Bool (or read_first_q (and start (not write))))
(define-fun new_first () Bool (or read_first_q (and shape (not write))))
(define-fun port_req () Bool (and bd_req (not (or probe (and start write)))))
(define-fun natural_first () (_ BitVec 3)
 ((_ extract 2 0) (bvsub (_ bv4096 13) ((_ zero_extend 1) linear_low))))
(define-fun first_mask () (_ BitVec 4)
 (bvsub (bvshl #x1 ((_ zero_extend 1) (ite active first natural_first))) #x1))
(define-fun saved_mask () (_ BitVec 4)
 (bvsub (bvshl #x1 ((_ zero_extend 1) first)) #x1))
(define-fun output_strobes ((first_select Bool)) (_ BitVec 4)
 (ite shift (bvlshr saved_strobes ((_ zero_extend 1) first))
  (ite mask_a (bvand strobes saved_mask)
   (ite read_second (bvlshr saved_strobes ((_ zero_extend 1) first))
    (ite first_select (bvand strobes first_mask) strobes)))))
(assert (and port_req (not (= (output_strobes old_first) (output_strobes new_first)))))
(check-sat)
'''
    if mutation == 'no-paging':
        text = text.replace('(and state_ok paging (or (not active) abort) cross)',
                            '(and state_ok (or (not active) abort) cross)')
    elif mutation == 'no-abort-replacement':
        text = text.replace('(and state_ok paging (or (not active) abort) cross)',
                            '(and state_ok paging (not active) cross)')
    elif mutation == 'no-cross':
        text = text.replace('(and state_ok paging (or (not active) abort) cross)',
                            '(and state_ok paging (or (not active) abort))')
    elif mutation == 'invalid-payload-witness':
        text = text.replace('(assert (and port_req ', '(assert (and (not port_req) ')
    elif mutation is not None:
        raise ValueError(mutation)
    return text


class FragmentReadPayload(unittest.TestCase):
    def sources(self):
        root = Path(os.environ['FRAGMENT_PAYLOAD_PARENT'])
        return (root.joinpath('core.sv').read_text(),
                root.joinpath('core_bus_driver.svh').read_text())

    def test_exact_one_consumer_change(self):
        core, bus = self.sources()
        candidate = transform(core, bus)
        self.assertEqual(candidate.replace(NEW, OLD), core)
        old_blocks, new_blocks = blocks(core), blocks(candidate)
        self.assertEqual(old_blocks[0], new_blocks[0])
        self.assertEqual(new_blocks[1].replace(NEW, OLD), old_blocks[1])

    def test_reject_source_drift(self):
        core, bus = self.sources()
        for a, b in ((core+'\n', bus), (core, bus+'\n'), (transform(core, bus), bus)):
            with self.subTest(core=a[-30:], bus=b[-30:]):
                with self.assertRaises(ValueError):
                    transform(a, b)

    def test_extraction_rejects_ambiguous_source(self):
        core, _ = self.sources()
        with self.assertRaises(ValueError):
            blocks(core+core)

    def test_binary_issued_payload_and_counterexamples(self):
        for mutation, answer in ((None, 'unsat'), ('no-paging', 'sat'),
                                 ('no-abort-replacement', 'sat'), ('no-cross', 'sat'),
                                 ('invalid-payload-witness', 'sat')):
            with self.subTest(mutation=mutation):
                result = subprocess.run(['/usr/bin/z3', '-in', '-smt2'],
                    input=proof(mutation), text=True, capture_output=True, timeout=15)
                self.assertEqual((result.returncode, result.stdout.strip(), result.stderr),
                                 (0, answer, ''))


if __name__ == '__main__':
    unittest.main()
