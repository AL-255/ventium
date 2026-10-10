"""Isolate the registered FP high-word payload from younger tag qualification.

Default-off private-tree recipe. The validity expression, all state, SRAM
ports, ACK and permission/coherence checks are unchanged. This is distinct
from the low-word selector: an exact primary dword can own a PARTIAL line.
"""

FLAG = 'VEN_L1D_HIGH_PAYLOAD_SELECT'
TARGET = 'rtl/mem/ven_l1d.sv'
OLD = '''  assign c_rdata_hi = shadow_reuse ?
      shadow_line_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32] :
      rd_window_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32];'''
VALID = '''  assign c_rdata_hi_valid = (L1_LINE == 32) && rst_n && c_req && !c_we &&
      c_ack && (c_wstrb == 4'hf) && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && !stream_path && !early_armed &&
      (st == L1_IDLE) && hit &&
      ((rd_full_line_q && (rd_match || window_reuse) &&
        (c_addr[31:5] == rd_addr_q[31:5])) || shadow_reuse) &&
      (c_addr[4:0] <= 5'd24)
`ifdef VEN_PIPE_MEM_CHAIN
      && !mc_lookup_next
`endif
`ifdef VEN_L1D_COMB_ACK
      && 1'b0 // never attach a registered high half to an asynchronous low half
`endif
      ;'''
REUSE = '''  assign shadow_reuse = shadow_valid_q && !mc_lookup_next && !stream_path &&
      !early_armed && (st == L1_IDLE) && c_req && !c_we && cacheable &&
      !golden && !flush_all && !snoop_inv_valid && hit &&
      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28)
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;'''
SELECT = '''  // Every omitted qualifier is already required by c_rdata_hi_valid.
  // Preserve shadow priority even with rd_match: the primary dword may be
  // valid while its upper FP word was borrowed by a different V-bank owner.
  wire shadow_high_payload_select = shadow_valid_q &&
      (c_addr[31:5] == shadow_line_addr_q)
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;'''
NEW = OLD.replace('shadow_reuse ?', 'shadow_high_payload_select ?')
GUARDS = '''`ifndef VEN_L1D_TWO_WINDOW_REUSE
  initial $fatal(1, "high payload selection requires two saved windows");
`endif
`ifndef VEN_PIPE_MEM_CHAIN
  initial $fatal(1, "high payload selection requires the checked lookahead profile");
`endif
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "high payload selection requires registered responses");
`endif'''
CHECKS = '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && c_rdata_hi_valid) begin
    assert (shadow_high_payload_select === shadow_reuse)
      else $fatal(1, "HIGH-WINDOW-PAYLOAD: changed valid owner");
    assert (c_rdata_hi === (shadow_reuse ?
        shadow_line_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32] :
        rd_window_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32]))
      else $fatal(1, "HIGH-WINDOW-PAYLOAD: changed valid data");
  end
`endif'''


def transform(source):
    if FLAG in source:
        raise ValueError('high window payload selection already present')
    for anchor in (OLD, VALID, REUSE):
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous high window contract: '+anchor)
    block = '\n'.join(('`ifdef '+FLAG, GUARDS, SELECT, NEW, CHECKS,
                        '`else', OLD, '`endif'))
    return source.replace(OLD, block)
