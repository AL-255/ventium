"""Remove fetch-demand size from the unused data-segment extent cone.

Keep one canonical per-state descriptor generator and the original bus size.
Only its data-limit consumer uses the value before the S_FETCH-only override.
No new state, cycle, permission policy, timing exception or feature define.
"""
import hashlib

FILE = 'rtl/core/core.sv'
PARENT = '259b394486502308f7e745b0ab1e0b821a9461283f12173fb24c9856dfbb0f6a'
FETCH_SIZE = "        if (sfetch_boundary) cur_size = {1'b0,sfetch_demand_size};\n"
TAP = """    // The data-limit checker never consumes an S_FETCH extent. Take its
    // beat size before applying the fetch-only demand override, so semantic
    // instruction decode cannot feed the data-limit comparator. Every data
    // state's width and whole-object override still have one producer.
    cur_data_size = cur_size;
    if ((state == S_FETCH) && sfetch_boundary)
      cur_size = {1'b0,sfetch_demand_size};
"""
DECL = """  logic [3:0] cur_data_size;
  wire [7:0] seg_data_ext_size = seg_ext_ovr_v ? seg_ext_ovr : {4'd0, cur_data_size};
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && cur_is_d)
    assert (seg_data_ext_size === seg_ext_size)
      else $fatal(1, "DATA-EXTENT-OWNER: changed data access size");
`endif
"""
ANCHOR = '    // A generic page-crossing beat proved its natural segment-relative\n'
ASSIGN = "  assign seg_ext_size = seg_ext_ovr_v ? seg_ext_ovr : {4'd0, cur_size};\n"


def edits():
    return [(FETCH_SIZE, ''), (ANCHOR, TAP + ANCHOR), (ASSIGN, ASSIGN + DECL),
            ('seg_extent_above(seg_chk_off, seg_ed_upper, seg_ext_size)',
             'seg_extent_above(seg_chk_off, seg_ed_upper, seg_data_ext_size)'),
            ('seg_extent_above(seg_chk_off, dlimit, seg_ext_size)',
             'seg_extent_above(seg_chk_off, dlimit, seg_data_ext_size)')]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('data-size source drift/reapplication')
    for before, after in edits():
        if source.count(before) != 1:
            raise ValueError('ambiguous data-size anchor: ' + before)
        source = source.replace(before, after)
    return source


def classification(source):
    start = source.index('  logic cur_is_d;\n')
    end = source.index('`ifdef VEN_L1D_CODE_BUFFER', start)
    return source[start:end]


def extent_function(source):
    start = source.index('  function automatic logic seg_extent_above(')
    end = source.index('  endfunction\n', start) + len('  endfunction\n')
    return source[start:end]


def symbolic():
    # A proof of the consumer cofactor, not a translated whole-core proof.
    return '''(set-logic QF_BV)
(declare-const fetch Bool)
(declare-const boundary Bool)
(declare-const data_owner Bool)
(declare-const override Bool)
(declare-const object_count (_ BitVec 8))
(declare-const data_count (_ BitVec 4))
(declare-const fetch_count (_ BitVec 3))
(assert (=> fetch (not data_owner)))
(define-fun bus_count () (_ BitVec 4)
  (ite (and fetch boundary) ((_ zero_extend 1) fetch_count) data_count))
(define-fun old () (_ BitVec 8)
  (ite override object_count ((_ zero_extend 4) bus_count)))
(define-fun new () (_ BitVec 8)
  (ite override object_count ((_ zero_extend 4) data_count)))
(assert (and data_owner (not (= old new))))
(check-sat)
'''
