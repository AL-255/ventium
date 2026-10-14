"""Factor fast-memory admission before the late segment selector.

This is a combinational identity, not a new admission policy or pipeline stage.
Generate a private derivative of the audited way-bank/fetch-page core; refuse
to apply to another revision. The bounded alternative remains DS-only.
"""
import hashlib

FILE = 'rtl/core/core.sv'
PARENT = '4606df0a39c042d5ff9cbe65c80b4841001643404bee765db9ee49384f353291'
START = '  logic sys_fp_load_ok;\n'
END = '\n  // A system fast store has the same narrow segment contract'
NEW = """  logic sys_fp_load_ok;
`ifdef VEN_SYS_FASTLOAD_FLAT
  // Descriptor predicates do not depend on this instruction's decoded segment.
  // Reduce each descriptor in parallel, then select one bit. In particular,
  // do not put a selected 32-bit limit mux ahead of the bounded DS comparison.
  logic sys_fp_normal_seg [NUM_SEG];
  logic sys_fp_flat_seg [NUM_SEG];
  for (genvar fs = 0; fs < NUM_SEG; fs++) begin : g_sys_fp_segment
    assign sys_fp_normal_seg[fs] = seg_attr[fs][7] && seg_attr[fs][4] &&
        !seg_attr[fs][3] && seg_attr[fs][1] && !seg_attr[fs][2];
    // A full-limit expand-down descriptor has an empty offset range, not a
    // flat range. Keep it on the precise segment-checking slow path.
    assign sys_fp_flat_seg[fs] = sys_fp_normal_seg[fs] &&
                               (seg_limit[fs] == 32'hFFFF_FFFF);
  end
  assign sys_fp_load_ok = sys_fp_ok && !real_mode && cs_d &&
                         (sys_fp_flat_seg[pipe_mem_seg]
`ifdef VEN_SYS_FASTLOAD_BOUNDED
                          || ((pipe_mem_seg == 3'(SG_DS)) &&
                              sys_fp_normal_seg[SG_DS] &&
                              seg_pm_loaded[SG_DS] &&
                              (seg_sel[SG_DS][15:2] != 14'd0) &&
                              (pipe_load_addr[31:12] < seg_limit[SG_DS][31:12]) &&
                              ((fp_mem_source_width(pipe_u_eff)==3'd1) ||
                               (pipe_load_addr[11:0] <=
                                ((fp_mem_source_width(pipe_u_eff)==3'd2) ? 12'hFFE : 12'hFFC))))
`endif
                         );
`else
  assign sys_fp_load_ok = 1'b0;
`endif
"""


def block(source):
    start = source.index(START)
    return source[start:source.index(END, start)]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fast-segment source drift/reapplication')
    old = block(source)
    assert source.count(old) == 1
    return source.replace(old, NEW)


def leaf(source):
    start = source.index(START)
    return source[start:source.index('\n  // Payload-independent CS limit check', start)]


def symbolic(mutant=None):
    # Two-state combinational cofactor proof, for every legal segment index.
    # Source width is deliberately unconstrained (not just widths 1/2/4).
    normal = '(and (= ((_ extract 7 7) a) #b1) (= ((_ extract 4 4) a) #b1) (= ((_ extract 3 3) a) #b0) (= ((_ extract 1 1) a) #b1) (= ((_ extract 2 2) a) #b0))'
    new_normal = normal.replace('(= ((_ extract 2 2) a) #b0)', 'true') if mutant == 'expand-down' else normal
    ds = '#b001' if mutant == 'wrong-segment' else '#b010'
    cmp = 'bvule' if mutant == 'inclusive-page' else 'bvult'
    word_end = '#xffc' if mutant == 'word-boundary' else '#xffe'
    return f'''(set-logic QF_ABV)
(declare-const attrs (Array (_ BitVec 3) (_ BitVec 8)))
(declare-const limits (Array (_ BitVec 3) (_ BitVec 32)))
(declare-const loaded (Array (_ BitVec 3) Bool))
(declare-const sels (Array (_ BitVec 3) (_ BitVec 16)))
(declare-const bases (Array (_ BitVec 3) (_ BitVec 32)))
(declare-const seg (_ BitVec 3))
(declare-const addr (_ BitVec 32))
(declare-const width (_ BitVec 3))
(declare-const flat Bool)
(declare-const bounded Bool)
(declare-const store_fast Bool)
(declare-const system_fast Bool)
(declare-const sys_ok Bool)
(declare-const real_mode Bool)
(declare-const cs_d Bool)
(declare-const w8 Bool)
(declare-const simple Bool)
(declare-const stack Bool)
(declare-const stk16 Bool)
(declare-const sys_mode Bool)
(declare-const is_store Bool)
(declare-const is_mem Bool)
(declare-const debug Bool)
(assert (bvult seg #b110))
(define-fun normal ((a (_ BitVec 8))) Bool {normal})
(define-fun new_normal ((a (_ BitVec 8))) Bool {new_normal})
(define-fun extent ((end2 (_ BitVec 12))) Bool
 (or (= width #b001) (bvule ((_ extract 11 0) addr) (ite (= width #b010) end2 #xffc))))
(define-fun old () Bool
 (and flat sys_ok (not real_mode) cs_d (normal (select attrs seg))
  (or (= (select limits seg) #xffffffff)
   (and bounded (= seg #b010) (select loaded seg)
    (not (= ((_ extract 15 2) (select sels seg)) (_ bv0 14)))
    (bvult ((_ extract 31 12) addr) ((_ extract 31 12) (select limits seg))) (extent #xffe)))))
(define-fun new () Bool
 (and flat sys_ok (not real_mode) cs_d
  (or (and (new_normal (select attrs seg)) (= (select limits seg) #xffffffff))
   (and bounded (= seg {ds}) (new_normal (select attrs {ds})) (select loaded {ds})
    (not (= ((_ extract 15 2) (select sels {ds})) (_ bv0 14)))
    ({cmp} ((_ extract 31 12) addr) ((_ extract 31 12) (select limits {ds}))) (extent {word_end})))))
(define-fun store ((load Bool)) Bool
 (and store_fast load (or w8 (bvule ((_ extract 11 0) (bvadd (select bases seg) addr)) #xffc))))
(define-fun bail ((load Bool)) Bool
 (ite system_fast
  (or (not simple) (and stack stk16) (and sys_mode (not sys_ok))
   (and sys_mode is_store (not (store load)))
   (and sys_mode is_mem (not is_store) (not load)) (and sys_mode debug))
  (or (not simple) sys_mode)))
(assert (or (not (= old new)) (not (= (store old) (store new))) (not (= (bail old) (bail new)))))
(check-sat)
'''
