"""Default-off current-response data selection, independent of next tag lookup.

This is a private-tree recipe, not a production enable. ACK, cache tags,
permissions, all sequential state and SRAM ports remain byte-for-byte intact.
"""

FLAG = 'VEN_L1D_RESPONSE_PAYLOAD_SELECT'
TARGET = 'rtl/mem/ven_l1d.sv'
OLD = '''                           : shadow_reuse ? shadow_line_q[{1'b0,c_addr[4:0],3'b000} +: 32]
                                         : rd_window_q[{1'b0,c_addr[4:0],3'b000} +: 32];'''
DECL = '''
`ifdef VEN_L1D_RESPONSE_PAYLOAD_SELECT
`ifndef VEN_L1D_TWO_WINDOW_REUSE
  initial $fatal(1, "response payload selection needs two saved windows");
`endif
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "response payload selection needs registered responses");
`endif
  // The exact registered owner has first choice of the primary bytes. Without
  // that owner, an ACK reaching this mux can only be primary/shadow reuse:
  // bypass, critical-fill and code-word data have already won above it, and
  // hit-stream overrides below. Their original ACK qualifications stay intact.
  // Neither a younger request's tag RAM nor its commit decision selects these
  // saved bytes. This is not permission to ACK an invalid/nonresident window.
  wire shadow_payload_select = !rd_match && shadow_valid_q &&
      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28);
`ifndef SYNTHESIS
  // Duplicate physical windows can arise from a same-line chained capture.
  // The original mux chose shadow on this overlap; both MUST contain the
  // same owned dword. Check the invariant, rather than silently assuming it.
  always_ff @(posedge clk) if (rst_n && c_req && !c_we && c_ack &&
                               rd_match && shadow_reuse) begin
    assert (rd_window_q[{1'b0,c_addr[4:0],3'b000} +: 32] ===
            shadow_line_q[{1'b0,c_addr[4:0],3'b000} +: 32])
      else $fatal(1, "RESPONSE-PAYLOAD-DUPLICATE: divergent saved owners");
  end
`endif
`endif
'''


def transform(source):
    if FLAG in source:
        raise ValueError('response payload selection already present')
    anchors = (OLD, '  // golden / "L1-useless" mode:',
               '  assign rd_match  = rd_armed && !stream_path && (rd_addr_q == c_addr)',
               '      assert (c_rdata === payload_before_cut)')
    for anchor in anchors:
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous response contract: ' + anchor)
    changed = source.replace(OLD,
        '`ifdef ' + FLAG + '\n' + OLD.replace('shadow_reuse ?', 'shadow_payload_select ?') +
        '\n`else\n' + OLD + '\n`endif')
    return changed.replace(anchors[1], DECL + '\n' + anchors[1])
