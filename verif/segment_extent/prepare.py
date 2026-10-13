"""Private data-segment extent arithmetic rewrite; no fault-policy change.

The late 8-bit count no longer feeds a 33-bit add/subtract and comparator.
Precompute whether the unsigned distance to the limit fits in one byte; if
it does, compare count to that small distance. Preserve zero-count behavior.
"""
import hashlib

PARENT = 'efa2152e931af8c14c90689694538fe01ff5956e2e98ece5ee4eb895249ca09e'
FILE = 'rtl/core/core.sv'
FUNCTION = """  // Exact unsigned 33-bit (offset + count - 1) > limit, for an 8-bit
  // count. Address/limit relations are early; the late extent sees only a
  // nine-bit comparison. Zero count retains the original underflow semantics.
  function automatic logic seg_extent_above(
      input logic [31:0] off, bound, input logic [7:0] count);
    logic [7:0] room;
    logic nearby;
    logic [32:0] zero_last;
    begin
      room = bound[7:0] - off[7:0];
      nearby = (off[31:8] == bound[31:8]) ||
          (({1'b0,off[31:8]} + 25'd1 == {1'b0,bound[31:8]}) &&
           (bound[7:0] < off[7:0]));
      zero_last = {1'b0,off} - 33'd1;
      seg_extent_above = (count == 8'd0) ? (zero_last > {1'b0,bound}) :
          ((off > bound) || (nearby && ({1'b0,count} > {1'b0,room} + 9'd1)));
    end
  endfunction

"""


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest()!=PARENT:
        raise ValueError('segment-extent source drift/reapplication')
    anchor = '  logic        seg_access_fault;\n'
    edits = [
        (anchor, anchor+FUNCTION),
        ('    logic [32:0] last_byte;\n', ''),
        ("    last_byte = {1'b0, seg_chk_off} + {25'd0, seg_ext_size} - 33'd1;\n",
         '    // The same canonical extent feeds both equivalent bound checks.\n'),
        ("(last_byte > {1'b0, seg_ed_upper})", 'seg_extent_above(seg_chk_off, seg_ed_upper, seg_ext_size)'),
        ("(last_byte > {1'b0,dlimit})", 'seg_extent_above(seg_chk_off, dlimit, seg_ext_size)'),
    ]
    for old,new in edits:
        if source.count(old)!=1: raise ValueError('segment-extent ambiguous anchor: '+old)
        source=source.replace(old,new)
    return source


def symbolic():
    return '''(set-logic QF_BV)
(declare-const off (_ BitVec 32))
(declare-const bound (_ BitVec 32))
(declare-const count (_ BitVec 8))
(define-fun old () Bool (bvugt
  (bvsub (bvadd ((_ zero_extend 1) off) ((_ zero_extend 25) count)) (_ bv1 33))
  ((_ zero_extend 1) bound)))
(define-fun room () (_ BitVec 8) (bvsub ((_ extract 7 0) bound) ((_ extract 7 0) off)))
(define-fun nearby () Bool (or
  (= ((_ extract 31 8) off) ((_ extract 31 8) bound))
  (and (= (bvadd ((_ zero_extend 1) ((_ extract 31 8) off)) (_ bv1 25))
          ((_ zero_extend 1) ((_ extract 31 8) bound)))
       (bvult ((_ extract 7 0) bound) ((_ extract 7 0) off)))))
(define-fun zero_last () (_ BitVec 33) (bvsub ((_ zero_extend 1) off) (_ bv1 33)))
(define-fun tail () Bool (and nearby (bvugt ((_ zero_extend 1) count)
  (bvadd ((_ zero_extend 1) room) (_ bv1 9)))))
(define-fun new () Bool (ite (= count #x00)
  (bvugt zero_last ((_ zero_extend 1) bound)) (or (bvugt off bound) tail)))
'''
