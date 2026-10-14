"""Exact response-mux cofactor for the frozen prefix-payload timing parent.

Keep the late code-access classification at one final data selector instead of
feeding it through the primary-owner comparison and shadow/code priority mux.
This changes no state, request, ACK, permission, byte offset or clock latency.
It is a private experiment; equivalence is not evidence of a frequency gain.
"""
import hashlib

FILE = 'rtl/mem/ven_l1d.sv'
PARENT = '62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3'
ANCHOR = '  // core-side response: HIT (read) returns combinationally; a write acks with the'
MUX_ANCHOR = '    // Use one primary-window byte selector, independent of window_reuse\'s'
GUARD = '`ifdef VEN_L1D_PAYLOAD_CODE_HINT\n`ifdef VEN_L1D_RESPONSE_PAYLOAD_SELECT\n'
END = '`endif\n`endif\n'
DECL = GUARD + '''  // Shannon cofactors of the complete registered response mux, not grants.
  // In particular, a partial instruction read still takes the data-class arm.
  // Do not remove c_wstrb from code_payload_access or the early-owner match.
  wire response_kind_rd_owner = rd_armed && !stream_path && (rd_addr_q == c_addr);
  wire response_kind_early_owner = early_armed && (c_addr == early_addr_q) &&
      (c_wstrb == early_wstrb_q);
  wire response_kind_shadow_owner = shadow_valid_q &&
      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28);
  wire [31:0] response_kind_primary = rd_window_q[{1'b0,c_addr[4:0],3'b000} +: 32];
  wire [31:0] response_kind_code =
      (response_kind_early_owner && early_code_q) ? early_rdata_q :
      (response_kind_rd_owner && rd_code_q) ? response_kind_primary :
      code_line_q[{c_addr[4:2],5'b00000} +: 32];
  wire [31:0] response_kind_data =
      (response_kind_early_owner && !early_code_q) ? early_rdata_q :
      (response_kind_rd_owner && !rd_code_q) ? response_kind_primary :
      response_kind_shadow_owner ? shadow_line_q[{1'b0,c_addr[4:0],3'b000} +: 32] :
      response_kind_primary;
''' + END + '\n'
MUX = GUARD + '''    // Same two-state value even on idle/unacknowledged cycles. Bypass still
    // wins here; the original hit-stream override below retains its priority.
    c_rdata = (st==L1_BYP) ? bp_line_x[{4'd0,fbase[1:0],3'b000} +: 32] :
        code_payload_access ? response_kind_code : response_kind_data;
''' + END


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('response-kind parent drift or reapplication')
    if source.count(ANCHOR) != 1 or source.count(MUX_ANCHOR) != 1:
        raise ValueError('response-kind insertion anchor drift')
    return source.replace(ANCHOR, DECL + ANCHOR).replace(MUX_ANCHOR, MUX + MUX_ANCHOR)


def formal(mutant=None):
    """All-bit, all-control two-state contract; not a sequential RTL proof."""
    result = '(set-logic QF_BV)\n'
    for name in ('kind', 'rd', 'rd_code', 'early', 'early_code', 'shadow', 'bypass', 'stream'):
        result += f'(declare-const {name} Bool)\n'
    for name in ('p', 'c', 'e', 's', 'b', 't'):
        result += f'(declare-const {name} (_ BitVec 32))\n'
    result += '''(define-fun rd_match () Bool (and rd (= rd_code kind)))
(define-fun early_match () Bool (and early (= early_code kind)))
(define-fun original () (_ BitVec 32)
  (ite stream t (ite bypass b (ite early_match e
    (ite (and kind (not rd_match)) c (ite (and (not rd_match) shadow) s p))))))
(define-fun code_arm () (_ BitVec 32)
  (ite (and early early_code) e (ite (and rd rd_code) p c)))
(define-fun data_arm () (_ BitVec 32)
  (ite (and early (not early_code)) e (ite (and rd (not rd_code)) p (ite shadow s p))))
'''
    expression = '(ite stream t (ite bypass b (ite kind code_arm data_arm)))'
    if mutant == 'reverse_kind':
        expression = expression.replace('ite kind', 'ite (not kind)')
    elif mutant == 'lost_stream':
        expression = '(ite bypass b (ite kind code_arm data_arm))'
    elif mutant is not None:
        raise ValueError(mutant)
    return result + f'(assert (not (= original {expression})))\n(check-sat)\n'
