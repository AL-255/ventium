; ACK-qualified primary-window payload algebra. This proves the Boolean/
; bit-vector lemma, not the cache FSM or synthesis timing. The RTL assertion
; checks the correspondence to real owners on every consumed read.
(set-logic QF_BV)
(declare-fun primary () (_ BitVec 512))
(declare-fun shadow () (_ BitVec 256))
(declare-fun critical () (_ BitVec 32))
(declare-fun bypass_data () (_ BitVec 32))
(declare-fun live () (_ BitVec 5))
(declare-fun saved () (_ BitVec 5))
(declare-fun bypass () Bool)
(declare-fun stream () Bool)
(declare-fun window_reuse () Bool)
(declare-fun shadow_reuse () Bool)
(declare-fun early_match () Bool)
(declare-fun rd_match () Bool)
(declare-fun ack () Bool)
(define-fun live_primary () (_ BitVec 32)
  ((_ extract 31 0) (bvlshr primary ((_ zero_extend 504) (concat live #b000)))))
(define-fun saved_primary () (_ BitVec 32)
  ((_ extract 31 0) (bvlshr primary ((_ zero_extend 504) (concat saved #b000)))))
(define-fun live_shadow () (_ BitVec 32)
  ((_ extract 31 0) (bvlshr shadow ((_ zero_extend 248) (concat live #b000)))))
; Both window policies require !early_armed; early_match requires early_armed.
(assert (=> (or window_reuse shadow_reuse) (not early_match)))
; A consumed non-stream read has one of these unchanged ACK owners.
(assert (=> ack (or stream bypass window_reuse shadow_reuse early_match rd_match)))
(define-fun old_payload () (_ BitVec 32)
  (ite stream saved_primary
    (ite bypass bypass_data
      (ite shadow_reuse live_shadow
        (ite window_reuse live_primary (ite early_match critical saved_primary))))))
(define-fun new_payload () (_ BitVec 32)
  (ite stream saved_primary
    (ite bypass bypass_data
      (ite early_match critical (ite shadow_reuse live_shadow live_primary)))))
(push)
; rd_match is an exact address match in RTL, stronger than this offset lemma.
(assert (=> rd_match (= live saved)))
(assert (and ack (not (= old_payload new_payload))))
(check-sat) ; must be unsat
(pop)
; Negative control: dropping the registered owner's address check is UNSAFE.
(assert (and ack rd_match (not (= live saved))
             (not (= old_payload new_payload))))
(check-sat) ; must be sat
