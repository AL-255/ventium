"""Exact one-file derivative: predecode both possible last-byte map regions.

Preserve the byte-exact access extent, every admission guard, and all state.
This recipe operates on the frozen SMSW + PRIME-REG composition, not root RTL.
"""
import hashlib

FILE = 'rtl/mem/ventium_l1_axi.sv'
PARENT = '8be78961aaede131862f1aea5bd6cc49b0873d29f5849a5c509aa655e803b7d9'
CACHEMAP = 'de1c3037470d72f3a4422aa58b4fd12b9dd9ef329682d8480037f76950bd8aba'

OLD_MAP = '''  ven_cachemap #(.SNAPSHOT_USER_HIGHMEM(CMAP_SNAPSHOT_USER_HIGHMEM)) u_cmap_dc_last (
      .addr(core_d_last), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_d_dram_last_u), .l1_cacheable(core_d_l1c_last),
      .l2_cacheable(core_d_l2c_last_u), .region(core_d_region_last));'''

NEW_MAP = '''  // The highest active byte is at most three bytes beyond core_addr.
  // ven_cachemap has no boundary within a 32-byte line. Decode the current
  // and following line in parallel; the short extent carry selects the tail.
  // This preserves both endpoints, including 32-bit address wraparound. Keep
  // core_d_last unchanged for arbitrary SMBASE/extent and diagnostic users.
  logic [31:0] core_d_next_line;
  logic [5:0] core_d_line_end;
  logic core_d_next_l1c, core_d_next_dram, core_d_next_l2c;
  logic [3:0] core_d_next_region;
  assign core_d_next_line = {core_addr[31:5] + 27'd1, 5'd0};
  assign core_d_line_end = {1'b0, core_addr[4:0]} +
      ((core_we || core_wstrb != 4'd0) ? {3'd0, core_d_hi} : 6'd3);
  ven_cachemap #(.SNAPSHOT_USER_HIGHMEM(CMAP_SNAPSHOT_USER_HIGHMEM)) u_cmap_dc_nextline (
      .addr(core_d_next_line), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_d_next_dram), .l1_cacheable(core_d_next_l1c),
      .l2_cacheable(core_d_next_l2c), .region(core_d_next_region));
  assign {core_d_dram_last_u, core_d_l1c_last, core_d_l2c_last_u, core_d_region_last} =
      core_d_line_end[5]
      ? {core_d_next_dram, core_d_next_l1c, core_d_next_l2c, core_d_next_region}
      : {core_d_dram_u, core_d_l1c, core_d_l2c_u, core_d_region};
`ifndef SYNTHESIS
  logic [6:0] core_d_original_last_map;
  ven_cachemap #(.SNAPSHOT_USER_HIGHMEM(CMAP_SNAPSHOT_USER_HIGHMEM)) u_cmap_dc_tail_check (
      .addr(core_d_last), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_d_original_last_map[6]), .l1_cacheable(core_d_original_last_map[5]),
      .l2_cacheable(core_d_original_last_map[4]), .region(core_d_original_last_map[3:0]));
  always_ff @(posedge core_clk) if (seam_core_rst_n)
    assert ({core_d_dram_last_u, core_d_l1c_last, core_d_l2c_last_u,
             core_d_region_last} === core_d_original_last_map)
      else $fatal(1,"ENDPOINT-MAP: changed last-byte attributes");
`endif'''

OLD_PCI = '''      assign pci_ok_last  = (core_d_region_last == 4'd6)
                         && ( ((core_d_last  & ~ADDR_MASK) == 32'd0)
                            || (core_d_last  >= 32'hFFFE_0000) );'''
OLD_EP = '''      assign ep_ok_last  = core_d_dram_last_u
                        || (core_d_region_last == 4'd2) || pci_ok_last;'''
NEW_EP = '''      // Most physical apertures cover whole lines. In that case routing
      // permission, too, can be computed before selecting the last endpoint.
      // A generic/noncontiguous mask may exclude a byte inside the line: retain
      // the exact original byte-address check for that parameterization.
      if ((ADDR_MASK & 32'h1f) == 32'h1f) begin : g_line_endpoint_route
        logic pci_ok_next;
        assign pci_ok_next = (core_d_next_region == 4'd6) &&
            (((core_d_next_line & ~ADDR_MASK) == 32'd0) ||
             (core_d_next_line >= 32'hFFFE_0000));
        assign pci_ok_last = core_d_line_end[5] ? pci_ok_next : pci_ok_first;
        assign ep_ok_last = core_d_line_end[5]
            ? (core_d_next_dram || (core_d_next_region == 4'd2) || pci_ok_next)
            : ep_ok_first;
      end else begin : g_byte_endpoint_route
        assign pci_ok_last = (core_d_region_last == 4'd6) &&
            (((core_d_last & ~ADDR_MASK) == 32'd0) || (core_d_last >= 32'hFFFE_0000));
        assign ep_ok_last = core_d_dram_last_u ||
            (core_d_region_last == 4'd2) || pci_ok_last;
      end
`ifndef SYNTHESIS
      always_ff @(posedge core_clk) if (seam_core_rst_n)
        assert (ep_ok_last === (core_d_dram_last_u ||
            (core_d_region_last == 4'd2) || ((core_d_region_last == 4'd6) &&
            (((core_d_last & ~ADDR_MASK) == 32'd0) || (core_d_last >= 32'hFFFE_0000)))))
          else $fatal(1,"ENDPOINT-MAP: changed last-byte route");
`endif'''


def edits():
    return [(OLD_MAP, NEW_MAP), (OLD_PCI, ''), (OLD_EP, NEW_EP)]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('endpoint-map source drift/reapplication')
    for old, new in edits():
        if source.count(old) != 1:
            raise ValueError('endpoint-map anchor drift')
        source = source.replace(old, new)
    return source
