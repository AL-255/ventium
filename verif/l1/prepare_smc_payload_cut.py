"""Private, exact-parent SMC address-mux experiment; no snoop is delayed.

The L1 selector uses U alignment instead of the late paired-store request.
The core gives its own crossing-line address priority over the external copy.
Only accepted *line* identity is invariant; idle addresses/low five bits are not.
The whole-core ownership assertions must pass before this can be promoted.
"""
import hashlib


PARENTS = {
    'rtl/mem/ventium_l1_axi.sv':
        'b0bdb4656083d8727264be4f9130dd9fb8b3384cc712cc3a76352af90cf7c95d',
    'rtl/core/core.sv':
        '70cc3e386aaa7c359b09021cd6c3e38803bfd6ab93533ede73611a74f9694837',
}
OLD_L1 = '''  assign icache_snoop_addr2  = core_store_pair_req ? core_store_pair_addr :
                               smc_last_phys;
'''
NEW_L1 = '''  // A paired U is an aligned dword; a <=4-byte crossing U cannot
  // be aligned. Keep late pair admission out of the I$ snoop address mux.
  // The existing VALID still authorizes exactly the original snoop edge.
  assign icache_snoop_addr2  = (core_addr[1:0] == 2'd0) ? core_store_pair_addr :
                               smc_last_phys;
`ifndef SYNTHESIS
  logic [31:0] smc_payload_old_l1;
  assign smc_payload_old_l1 = core_store_pair_req ? core_store_pair_addr : smc_last_phys;
  always_ff @(posedge core_clk) if (seam_core_rst_n) begin
    if (core_store_pair_req)
      assert (core_addr[1:0] == 2'd0)
        else $fatal(1, "SMC-PAYLOAD: paired U is not aligned");
    if (icache_snoop_valid2)
      assert (icache_snoop_addr2 === smc_payload_old_l1)
        else $fatal(1, "SMC-PAYLOAD: active L1 address changed");
  end
`endif
'''
OLD_CORE = '  assign icsnp_a2 = ic_snoop_valid2 ? ic_snoop_addr2 : smc_a2;\n'
NEW_CORE = '''`ifdef VEN_P54_DUAL_STORE_PAIR
  // The own crossing snoop and the L1 copy describe the same physical
  // line. An aligned U/V pair cannot also be an own crossing store.
  // Preserve the existing OR of VALIDs and all same-cycle invalidations.
  assign icsnp_a2 = smc_v2 ? smc_a2 : ic_snoop_addr2;
`ifndef SYNTHESIS
  logic [31:0] smc_payload_old_core;
  assign smc_payload_old_core = ic_snoop_valid2 ? ic_snoop_addr2 : smc_a2;
  always_ff @(posedge clk) if (rst_n && icsnp_v2) begin
    assert (icsnp_a2[31:5] === smc_payload_old_core[31:5])
      else $fatal(1, "SMC-PAYLOAD: active core snoop line changed");
    if (smc_v2 && ic_snoop_valid2)
      assert (smc_a2[31:5] === ic_snoop_addr2[31:5])
        else $fatal(1, "SMC-PAYLOAD: conflicting crossing snoop owners");
  end
`endif
`else
'''+OLD_CORE+'''`endif
'''


def transform(path, source):
    if path not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[path]:
        raise ValueError('SMC payload predecessor drift/reapplication: '+path)
    old, new = (OLD_L1, NEW_L1) if path.endswith('ventium_l1_axi.sv') else (OLD_CORE, NEW_CORE)
    if source.count(old) != 1:
        raise ValueError('ambiguous SMC address selector: '+path)
    return source.replace(old, new)
