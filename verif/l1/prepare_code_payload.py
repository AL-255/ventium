"""Private timing experiment: select saved instruction bytes by response owner.

ACK, capture, validity, SRAM organization and all state transitions are unchanged.
The flag is default-off and requires the registered instruction-buffer profile.
"""

FLAG = 'VEN_L1D_CODE_PAYLOAD_SELECT'
TARGET = 'rtl/mem/ven_l1d.sv'
OLD = '                           : code_word_reuse ? code_line_q[{c_addr[4:2],5\'b00000} +: 32]'
NEW = OLD.replace('code_word_reuse ?', 'code_payload_select ?')
DECL = '  logic code_word_reuse;'
SHADOW_GUARD = '''      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28)
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif'''
PRIMARY_GUARD = '''  assign window_reuse = window_valid_q && !mc_lookup_next && !stream_path && !early_armed &&
`ifdef VEN_L1D_CODE_BUFFER
      !code_access &&
`endif'''
SELECT = '''  // Bypass/critical responses win before this selector; stream overrides
  // it afterwards. On the remaining consumed code read, either rd_match owns
  // the primary dword or code_word_reuse owns the staging-line bytes. A younger
  // lookup and its tag result need not select the already registered payload.
  wire code_payload_select = code_access && !rd_match;'''
GUARDS = '''`ifndef VEN_L1D_CODE_WORD_REUSE
  initial $fatal(1, "code payload selection requires code word reuse");
`endif
`ifndef VEN_L1D_CODE_BUFFER
  initial $fatal(1, "code payload selection requires the instruction buffer");
`endif
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "code payload selection requires registered responses");
`endif'''
CHECK = '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && c_req && !c_we && c_ack &&
      !stream_path && (st != L1_BYP) && !early_match) begin
    if (code_payload_select)
      assert (code_word_reuse)
        else $fatal(1, "CODE-PAYLOAD-OWNER: selected unowned code bytes");
    // If both owners coexist, selecting the exact primary dword is valid only
    // if it is byte-identical to the instruction staging line. Check, don't
    // assume, this sequential invariant. The existing full mux miter remains.
    if (rd_match && code_word_reuse)
      assert (rd_window_q[{1'b0,c_addr[4:0],3'b000} +: 32] ===
              code_line_q[{c_addr[4:2],5'b00000} +: 32])
        else $fatal(1, "CODE-PAYLOAD-DUPLICATE: divergent registered owners");
  end
`endif'''


def transform(source):
    if FLAG in source:
        raise ValueError('code payload selector already present')
    for anchor in (OLD, DECL, '  assign code_word_reuse = rst_n && c_req && code_access &&',
                   SHADOW_GUARD, PRIMARY_GUARD,
                   '                                 code_word_reuse ||'):
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous code ownership contract: '+anchor)
    # Place legality guards outside the required CODE_WORD_REUSE block, so an
    # unsupported flag combination cannot silently compile as a no-op.
    top = '  // ---- combinational lookup off the registered arrays (PRE-update) ----------'
    if source.count(top) != 1:
        raise ValueError('missing module-scope guard anchor')
    source = source.replace(top, '`ifdef '+FLAG+'\n'+GUARDS+'\n`endif\n\n'+top)
    source = source.replace(DECL, DECL+'\n`ifdef '+FLAG+'\n'+SELECT+'\n'+CHECK+'\n`endif')
    return source.replace(OLD, '`ifdef '+FLAG+'\n'+NEW+'\n`else\n'+OLD+'\n`endif')
