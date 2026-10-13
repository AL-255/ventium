"""Boolean/bitvector lemma for the proposed fast-memory CS-extent cofactor.

This is a mathematical model of the pinned expressions, not a symbolic
translation of SystemVerilog or a whole-core proof. Native extracted-RTL
miters and complete regression gates remain required before promotion.
"""


def problem():
    booleans = ('seg_en fp_pipe sys real v86 present active issue_block exec_ok '
                'frontend stall_zero penalty_zero rd_haz is_fp sys_bail '
                'bubble_zero agi is_mem is_store held_we header_zero early_nm early_gp').split()
    text = '(set-logic QF_BV)\n'
    text += ''.join(f'(declare-const {n} Bool)\n' for n in booleans)
    # Symbolic state equivalence classes: PIPE=1, DECODE=2, any other state.
    # Their concrete enum numbers need not be fixed across feature profiles.
    for n,bits in (('state',2),('eip',32),('limit',32),('u_len',4),('held_len',4),('d_len',4)):
        text += f'(declare-const {n} (_ BitVec {bits}))\n'
    terms = [
        ('pipe', 'Bool', '(= state #b01)'),
        ('decode', 'Bool', '(= state #b10)'),
        ('effective_len', '(_ BitVec 4)', '(ite active held_len u_len)'),
        ('end_u', '(_ BitVec 33)', '(bvsub (bvadd ((_ zero_extend 1) eip) ((_ zero_extend 29) u_len)) (_ bv1 33))'),
        ('end_eff', '(_ BitVec 33)', '(bvsub (bvadd ((_ zero_extend 1) eip) ((_ zero_extend 29) effective_len)) (_ bv1 33))'),
        ('end_d', '(_ BitVec 33)', '(bvsub (bvadd ((_ zero_extend 1) eip) ((_ zero_extend 29) d_len)) (_ bv1 33))'),
        ('mode', 'Bool', '(and seg_en sys (not real) (not v86) present)'),
        ('preissue', 'Bool', '(and pipe (not active) (not issue_block) exec_ok frontend stall_zero penalty_zero (or (not fp_pipe) (not rd_haz)))'),
        ('integer_ok', 'Bool', '(and (not sys_bail) bubble_zero (not agi))'),
        ('eligible', 'Bool', '(and preissue (or is_fp integer_ok))'),
        ('old_fault', 'Bool', '(and mode (or (and pipe eligible (bvugt end_eff ((_ zero_extend 1) limit))) (and decode (not (= d_len #x0)) header_zero (not early_nm) (not early_gp) (bvugt end_d ((_ zero_extend 1) limit)))))'),
        ('new_fault', 'Bool', '(and mode (bvugt end_u ((_ zero_extend 1) limit)))'),
        ('load_base', 'Bool', '(and preissue integer_ok is_mem (not is_store))'),
        ('store_base', 'Bool', '(and preissue integer_ok is_store)'),
        ('old_load', 'Bool', '(and load_base (not old_fault))'),
        ('new_load', 'Bool', '(and load_base (not new_fault))'),
        ('old_store', 'Bool', '(and store_base (not old_fault))'),
        ('new_store', 'Bool', '(and store_base (not new_fault))'),
        ('old_held_load', 'Bool', '(ite active (and pipe (not held_we)) old_load)'),
        ('new_held_load', 'Bool', '(ite active (and pipe (not held_we)) new_load)'),
        ('old_held_store', 'Bool', '(ite active (and pipe held_we) old_store)'),
        ('new_held_store', 'Bool', '(ite active (and pipe held_we) new_store)'),
        ('end32', '(_ BitVec 32)', '(bvsub (bvadd eip ((_ zero_extend 28) u_len)) (_ bv1 32))'),
        ('wrong32_fault', 'Bool', '(and mode (bvugt end32 limit))'),
    ]
    for name,kind,expr in terms:
        text += f'(define-fun {name} () {kind} {expr})\n'
    return text


QUERIES = [
    ('all_requests', '(or (not (= old_load new_load)) (not (= old_store new_store)) (not (= old_held_load new_held_load)) (not (= old_held_store new_held_store)))', 'unsat'),
    # Show that the local cofactor is not a replacement for global delivery.
    ('unsafe_global_replacement', '(and decode (not (= old_fault new_fault)))', 'sat'),
    ('overflow_must_keep_bit32', '(and load_base (= eip #xffffffff) (= u_len #x2) (= limit #xffffffff) old_fault (not wrong32_fault))', 'sat'),
    ('zero_length_underflow', '(and load_base (= eip #x00000000) (= u_len #x0) (= limit #xffffffff) old_fault (not wrong32_fault))', 'sat'),
    ('lost_limit_guard', '(and store_base old_fault)', 'sat'),
    ('instruction_ends_at_limit', '(and load_base mode (= end_u ((_ zero_extend 1) limit)) old_fault)', 'unsat'),
]
