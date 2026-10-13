; Manually stated binary owner/selector contract, not automatic SV formal
; elaboration or an inductive proof of the core's owner state machine.
(set-logic QF_BV)
(declare-const held Bool)
(declare-const active Bool)
(declare-const write Bool)
(declare-const request Bool)
(declare-const valid Bool)
(declare-const ack Bool)
(declare-const immediate_data (_ BitVec 32))
(declare-const held_data (_ BitVec 32))
(define-fun immediate () Bool (and request valid ack (not active)))
(define-fun owner () Bool (or (not held) (and active (not write))))
(define-fun consumed () Bool (or held immediate))
(define-fun old_data () (_ BitVec 32) (ite immediate immediate_data held_data))
(define-fun new_data () (_ BitVec 32) (ite held held_data immediate_data))

; The existing owner invariant excludes overlapping immediate/held responses.
(push 1)
(assert owner)
(assert (and held immediate))
(check-sat)
(pop 1)

; Every payload bit agrees whenever the load arm consumes the value.
(push 1)
(assert owner)
(assert consumed)
(assert (distinct old_data new_data))
(check-sat)
(pop 1)

; Without the owner invariant, the same cut is unsafe.
(push 1)
(assert consumed)
(assert (distinct old_data new_data))
(check-sat)
(pop 1)

; No-consumer payload equality is intentionally NOT a requirement.
(push 1)
(assert owner)
(assert (not consumed))
(assert (distinct old_data new_data))
(check-sat)
(pop 1)

; Two real wrong-source mutations are observable under the valid contract.
(push 1)
(assert owner)
(assert consumed)
(assert (distinct old_data held_data))
(check-sat)
(pop 1)
(push 1)
(assert owner)
(assert consumed)
(assert (distinct old_data immediate_data))
(check-sat)
(pop 1)
