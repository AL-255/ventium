// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_frame_plan -- bounded, sequential page plan for a privilege-frame push.
//
// A cross-privilege interrupt/call-gate frame contains at most 35 slots and
// spans at most four pages.  The old in-core implementation enumerated all
// 36 possible slots and their duplicate comparisons in one cycle.  Besides
// being needlessly wide for a rare path, that made the frame-plan register D
// inputs a several-hundred-level cone.  This service visits one slot page at a
// time.  It is entered before any new SS/CPL state is committed, so the extra
// cycles cannot become architecturally visible and a fault still observes the
// original context.

`default_nettype none

module ven_frame_plan (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire logic [31:0] stack_base,
    input  wire logic [31:0] stack_ptr,
    input  wire logic        stack_b32,
    input  wire logic        wide,
    input  wire logic [5:0]  nslots,
    output      logic        busy,
    output      logic        done,
    output      logic [19:0] page_lin [4],
    output      logic [31:0] probe_addr [4],
    output      logic [3:0]  page_valid,
    output      logic [3:0]  page_mid
);

  logic [31:0] base_q, sp_q;
  logic        b32_q, wide_q, busy_q, phase_q;
  logic [5:0]  nslots_q, slot_q;
  logic [2:0]  count_q;

  logic [31:0] slot_off_w, slot_addr_w, slot_last_w, cand_addr_w;
  logic [19:0] cand_page_w;
  logic        cand_mid_w, cand_dup_w, slot_straddles_w;

  function automatic logic [31:0] slot_off(
      input logic [31:0] sp,
      input logic [5:0]  slot,
      input logic        is_wide,
      input logic        is_b32
  );
    logic [31:0] amount;
    begin
      amount  = is_wide ? ({26'd0, slot} + 32'd1) << 2
                        : ({26'd0, slot} + 32'd1) << 1;
      slot_off = is_b32 ? sp - amount : {16'd0, sp[15:0] - amount[15:0]};
    end
  endfunction

  always_comb begin
    slot_off_w       = slot_off(sp_q, slot_q, wide_q, b32_q);
    slot_addr_w      = base_q + slot_off_w;
    slot_last_w      = slot_addr_w + (wide_q ? 32'd3 : 32'd1);
    slot_straddles_w = (slot_addr_w[31:12] != slot_last_w[31:12]);
    cand_mid_w       = phase_q;
    cand_addr_w      = phase_q ? {slot_last_w[31:12], 12'd0} : slot_addr_w;
    cand_page_w      = cand_addr_w[31:12];
    cand_dup_w       = 1'b0;
    for (int i = 0; i < 4; i++)
      if ((i < count_q) && (page_lin[i] == cand_page_w)) cand_dup_w = 1'b1;
  end

  always_comb begin
    page_valid = 4'd0;
    for (int i = 0; i < 4; i++)
      if (i < count_q) page_valid[i] = 1'b1;
  end

  assign busy = busy_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      base_q   <= 32'd0;
      sp_q     <= 32'd0;
      b32_q    <= 1'b0;
      wide_q   <= 1'b0;
      nslots_q <= 6'd0;
      slot_q   <= 6'd0;
      count_q  <= 3'd0;
      phase_q  <= 1'b0;
      busy_q   <= 1'b0;
      done     <= 1'b0;
      page_mid <= 4'd0;
      for (int i = 0; i < 4; i++) begin
        page_lin[i]   <= 20'd0;
        probe_addr[i] <= 32'd0;
      end
    end else if (start) begin
      base_q   <= stack_base;
      sp_q     <= stack_ptr;
      b32_q    <= stack_b32;
      wide_q   <= wide;
      nslots_q <= nslots;
      slot_q   <= 6'd0;
      count_q  <= 3'd0;
      phase_q  <= 1'b0;
      busy_q   <= (nslots != 6'd0);
      done     <= (nslots == 6'd0);
      page_mid <= 4'd0;
      for (int i = 0; i < 4; i++) begin
        page_lin[i]   <= 20'd0;
        probe_addr[i] <= 32'd0;
      end
    end else if (busy_q) begin
      if (!cand_dup_w) begin
`ifndef SYNTHESIS
        if (count_q == 3'd4)
          $fatal(1, "frame page plan overflow (>4 pages)");
`endif
        if (count_q < 3'd4) begin
          page_lin[count_q[1:0]]   <= cand_page_w;
          probe_addr[count_q[1:0]] <= cand_addr_w;
          page_mid[count_q[1:0]]   <= cand_mid_w;
          count_q             <= count_q + 3'd1;
        end
      end

      if (!phase_q && slot_straddles_w) begin
        phase_q <= 1'b1;
      end else if (slot_q == nslots_q - 6'd1) begin
        busy_q <= 1'b0;
        done   <= 1'b1;
      end else begin
        slot_q  <= slot_q + 6'd1;
        phase_q <= 1'b0;
      end
    end
  end

endmodule : ven_frame_plan

`default_nettype wire
