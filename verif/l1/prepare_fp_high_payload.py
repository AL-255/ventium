"""Default-off wide FP payload transport; keep response qualification intact.

The high word is sampled only under core_rdata_hi_valid. Its old zeroing
mux serializes ACK ahead of FP conversion. Preserve the raw-reset and denied
route/SMRAM zeroing contract, but do not wait for acceptance to present data.
This changes invalid-cycle payload only; it adds no state or cache port.
"""

FLAG = 'VEN_FP_LOAD64_PAYLOAD_SELECT'
TARGET = 'rtl/mem/ventium_l1_axi.sv'
REQUEST = '''  assign l1d_c_req  = seam_core_rst_n && core_req && !core_smram_deny
                  && !core_route_deny && !dma_drain_stall;'''
VALID = '''  assign core_rdata_hi_valid = l1d_c_req && l1d_c_ack &&
      core_d_l1c && core_d_l1c_last && !cr0_cd && l1d_c_rdata_hi_valid;'''
OLD = "  assign core_rdata_hi = core_rdata_hi_valid ? l1d_c_rdata_hi : 32'd0;"
NEW = '''  // Valid alone owns consumption. Do not serialize ACK before the FP
  // operand converter; reset and access-denial blanking still apply.
  assign core_rdata_hi = !seam_core_rst_n ? 32'd0 :
      (core_smram_deny || core_route_deny) ? 32'd0 : l1d_c_rdata_hi;'''


def transform(source):
    if FLAG in source:
        raise ValueError('wide payload selection already present')
    for anchor in (REQUEST, VALID, OLD):
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous wide-response contract: '+anchor)
    checks = '''
`ifndef SYNTHESIS
  always_ff @(posedge core_clk) if (core_rdata_hi_valid) begin
    assert (seam_core_rst_n && !core_smram_deny && !core_route_deny &&
            core_rdata_hi === l1d_c_rdata_hi)
      else $fatal(1, "FP-HIGH-PAYLOAD-OWNER: changed a valid wide response");
  end
`endif'''
    return source.replace(OLD, '`ifdef '+FLAG+'\n'+NEW+checks+
                          '\n`else\n'+OLD+'\n`endif')
