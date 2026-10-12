"""Exact fresh-U capture cofactor of the closed READ-OWNER FPGA source.

Do not apply to an existing pinned export. Only the fresh capture predicate
changes; actual U capture, prime capture, bank selection and state do not.
"""
import hashlib

PARENT = 'fd235f7706cba770ba898dd49d9d8c2a698b42e836c3716af204c2779b56816e'
START = '  assign pair_legacy_capture = (pair_req_valid == 2\'b10) &&\n'
END = '  assign pair_bank_conflict = pair_arb_conflict ||\n'

NEW = '''  // A fresh current read has c_req && !rd_armed. The old-owner
  // lookahead requires rd_match (hence rd_armed); prime requires !c_req.
  // Both are impossible here. Use current tags, not the selected-next mux.
  logic pair_fresh_current_hit, pair_fresh_saved_window;
`ifdef VEN_PIPE_MEM_CHAIN
  assign pair_fresh_current_hit = |tag_current_hit;
`else
  assign pair_fresh_current_hit = hit;
`endif
  // All other reuse qualifiers are supplied by the capture predicate below.
  // Retain flush and extent here: a saved window can survive rd_armed, but
  // does not serve byte 29..31 and is not reusable during a flush. Do not add
  // a global !flush_all to capture: the outer bank guard already owns that.
  assign pair_fresh_saved_window =
`ifdef VEN_L1D_WINDOW_REUSE
      !flush_all && (c_addr[4:0] <= 5'd28) &&
      ((window_valid_q && (c_addr[31:5] == rd_addr_q[31:5]))
`ifdef VEN_L1D_TWO_WINDOW_REUSE
       || (shadow_valid_q && (c_addr[31:5] == shadow_line_addr_q))
`endif
      );
`else
      1'b0;
`endif
  assign pair_legacy_capture = (pair_req_valid == 2'b10) &&
      c_req && !c_we && cacheable && !golden && !rd_armed &&
      (st == L1_IDLE) && !early_armed && !stream_path && !snoop_inv_valid &&
      pair_fresh_current_hit && !pair_fresh_saved_window &&
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
      ((c_wstrb == 4'h1) ||
       ((c_wstrb == 4'hf) && (c_addr[1:0] == 2'd0)))
`else
      (c_wstrb == 4'hf) && (c_addr[1:0] == 2'd0)
`endif
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;
'''


def original_capture(source):
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError('fresh-pair capture anchors drifted')
    begin, end = source.index(START), source.index(END)
    if end <= begin:
        raise ValueError('fresh-pair capture order drifted')
    return source[begin:end]


def witness(original):
    return '''`ifndef SYNTHESIS
  logic pair_fresh_capture_before_cut;
''' + original.replace('assign pair_legacy_capture =',
                       'assign pair_fresh_capture_before_cut =') + '''  always_ff @(posedge clk) if (rst_n) begin
    assert (pair_legacy_capture === pair_fresh_capture_before_cut)
      else $fatal(1,"FRESH-PAIR-CAPTURE: changed fresh U bank admission");
    if (c_req && !rd_armed)
      assert (!mc_lookup_next)
        else $fatal(1,"FRESH-PAIR-CAPTURE: unexpected next lookup");
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fresh-pair predecessor drift/reapplication')
    old = original_capture(source)
    return source.replace(old, NEW + witness(old))
