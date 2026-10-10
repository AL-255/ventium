; Combinational selector lemma, NOT a proof of the cache's sequential invariant.
; Reuse shares the same qualification (hit, permissions, state, cancellations,
; no lookahead) for both buffers. Earlier bypass/critical/code muxes and the
; hit-stream override are identical and are excluded from this inner mux.
(set-logic QF_BV)
(declare-fun common () Bool)
(declare-fun owned () Bool)
(declare-fun primary-valid () Bool)
(declare-fun primary-match () Bool)
(declare-fun shadow-valid () Bool)
(declare-fun shadow-match () Bool)
(declare-fun contained () Bool)
(declare-fun primary-data () (_ BitVec 32))
(declare-fun shadow-data () (_ BitVec 32))
(define-fun primary-reuse () Bool (and common primary-valid primary-match contained))
(define-fun shadow-reuse () Bool (and common shadow-valid shadow-match contained))
(define-fun ack () Bool (or owned primary-reuse shadow-reuse))
(define-fun select-shadow () Bool (and (not owned) shadow-valid shadow-match contained))
(define-fun original () (_ BitVec 32) (ite shadow-reuse shadow-data primary-data))
(define-fun candidate () (_ BitVec 32) (ite select-shadow shadow-data primary-data))
(define-fun duplicate-invariant () Bool
  (=> (and owned shadow-reuse) (= primary-data shadow-data)))
(push)
(assert duplicate-invariant)
(assert ack)
(assert (distinct original candidate))
(check-sat) ; required unsat
(pop)
; Required negative: without the duplicate-owner invariant this is NOT safe.
(push)
(assert ack)
(assert (distinct original candidate))
(check-sat) ; required sat
(pop)
; Required negative: dropping physical shadow identity is NOT safe.
(push)
(assert duplicate-invariant)
(assert ack)
(assert (distinct original
  (ite (and (not owned) shadow-valid contained) shadow-data primary-data)))
(check-sat) ; required sat
(pop)
