// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private combinational factoring of the existing prefix/EX successor window.
// No new read port, cache state, byte permission or issue/retirement rule.
`ifndef VEN_P54_PREFIX_EX_CHAIN
  initial $fatal(1, "IC prefix span requires the existing prefix/EX consumer");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "IC prefix span requires registered I-cache ownership");
`endif
`ifdef VEN_IC_BRAM
  // The original consumer adds a full-width constant even for byte zero.
  // Retain that four-state arithmetic behavior for partially unknown bases.
  wire [31:0] ic_prefix_base = p54_prefix_ex_flin + 32'd0;
  wire [31:0] ic_prefix_next = {ic_prefix_base[31:5],5'd0} + 32'd32;
  logic [IC_WAYW:0] ic_prefix_a, ic_prefix_b;
  logic [IC_LINE*8-1:0] ic_prefix_lineA, ic_prefix_lineB;
  wire [7:0] ic_prefix_bytes [IWORDS*4];

  always_comb begin
    // Same ordered cache-way/bypass priority as the generic ic_hit_way.
    ic_prefix_a = ic_front_probe(ic_prefix_base);
    ic_prefix_b = ic_front_probe(ic_prefix_next);
    // Preserve A priority, collision rejection, stale-A fallback, and the
    // ternary's bitwise merge if a returned identity is unknown.
    ic_prefix_lineA =
        (rdA_set_q == ic_prefix_base[5 +: IC_IDXW] &&
         rdA_way_q == ic_prefix_a[IC_WAYW-1:0] && !ic_rd_collA) ? ic_rd_lineA :
        (rdB_set_q == ic_prefix_base[5 +: IC_IDXW] &&
         rdB_way_q == ic_prefix_a[IC_WAYW-1:0] && !ic_rd_collB) ? ic_rd_lineB : ic_rd_lineA;
    ic_prefix_lineB =
        (rdA_set_q == ic_prefix_next[5 +: IC_IDXW] &&
         rdA_way_q == ic_prefix_b[IC_WAYW-1:0] && !ic_rd_collA) ? ic_rd_lineA :
        (rdB_set_q == ic_prefix_next[5 +: IC_IDXW] &&
         rdB_way_q == ic_prefix_b[IC_WAYW-1:0] && !ic_rd_collB) ? ic_rd_lineB : ic_rd_lineA;
  end
  for (genvar prefix_i=0; prefix_i<IWORDS*4; prefix_i++) begin : g_ic_prefix_span
    wire [5:0] pos = {1'b0,ic_prefix_base[4:0]} + 6'(prefix_i);
    assign ic_prefix_bytes[prefix_i] = pos[5]
        ? ic_prefix_lineB[{pos[4:0],3'b000} +: 8]
        : ic_prefix_lineA[{pos[4:0],3'b000} +: 8];
  end
`endif
