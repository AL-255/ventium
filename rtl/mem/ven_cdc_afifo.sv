// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_cdc_afifo.sv — a clean-room 2-FF Gray-pointer asynchronous FIFO (P1-3).
//
// The ONE clock-domain-crossing primitive for the dual-clock L1/AXI build
// (+VEN_AXI_CDC): the core runs in core_clk (the slower, Fmax-limited domain) and
// the AXI master / PS-DDR run in axi_clk (a faster MMCM clock to S_AXI_HPC0). This
// FIFO carries a data stream safely between the two. It is the canonical Cummings
// structure (a public, license-free algorithm — written from the textbook, no
// proprietary source): binary+Gray pointers, a 2-flop synchronizer per pointer, and
// the Gray-code property that exactly ONE bit changes per increment, so a metastable
// synchronizer sample always resolves to either the old or the new count — never a
// corrupt intermediate. That structural guarantee (not simulation) is what makes the
// crossing metastability-safe; Verilator then proves the functional protocol across
// clock ratios (verif/l1/tb_l1axi_cdc.sv).
//
// full/empty are computed from each domain's OWN registered Gray pointer compared
// against the synchronized remote pointer (NOT the combinational _nxt — that forms a
// pointer→full→pointer loop). The remote pointer always LAGS (sync latency), so empty
// is pessimistic on the read side (never reads an entry not yet committed) and full is
// pessimistic on the write side (never overwrites) — the two safety guarantees.
//
// READ is FIRST-WORD-FALL-THROUGH: rd_data combinationally presents the head while
// !rd_empty (mem read is async off a distributed-RAM array), and rd_en advances the
// read pointer. This matches the ven_l1d backing contract exactly — a consumer that
// latches rd_data on the posedge it sees its ack, with no extra latency cycle.
//
// DEPTH must be a power of two ≥ 4 (Gray pointers + the full-detect slice).

module ven_cdc_afifo #(
    parameter int W     = 32,
    parameter int DEPTH = 16          // power of two, >= 4
) (
    // write domain
    input  logic         wr_clk,
    input  logic         wr_rst_n,
    input  logic         wr_en,
    input  logic [W-1:0] wr_data,
    output logic         wr_full,
    // read domain
    input  logic         rd_clk,
    input  logic         rd_rst_n,
    input  logic         rd_en,
    output logic [W-1:0] rd_data,
    output logic         rd_empty
);
  localparam int AW = $clog2(DEPTH);

`ifndef SYNTHESIS
  initial begin
    if ((DEPTH & (DEPTH-1)) != 0)
      $fatal(1, "ven_cdc_afifo: DEPTH (%0d) must be a power of two", DEPTH);
    if (DEPTH < 4)
      $fatal(1, "ven_cdc_afifo: DEPTH (%0d) must be >= 4", DEPTH);
  end
`endif

  // storage — distributed RAM, async (combinational) read for FWFT.
  logic [W-1:0] mem [DEPTH];

  // pointers are AW+1 bits: the extra MSB distinguishes full from empty (one wrap).
  logic [AW:0] wbin, wbin_nxt, wgray, wgray_nxt;   // write domain
  logic [AW:0] rbin, rbin_nxt, rgray, rgray_nxt;   // read domain

  // cross-domain synchronized Gray pointers (2-flop, ASYNC_REG).
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wq1_rgray, wq2_rgray;  // rd ptr -> wr domain
  (* ASYNC_REG = "TRUE" *) logic [AW:0] rq1_wgray, rq2_wgray;  // wr ptr -> rd domain

  // ---- write pointer + full ------------------------------------------------
  assign wbin_nxt  = wbin + {{AW{1'b0}}, (wr_en & ~wr_full)};   // zero-extend the +1
  assign wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
  always_ff @(posedge wr_clk or negedge wr_rst_n)
    if (!wr_rst_n) begin wbin <= '0; wgray <= '0; end
    else           begin wbin <= wbin_nxt; wgray <= wgray_nxt; end
  // FULL: this domain's Gray == synced read Gray with the TOP TWO bits inverted.
  assign wr_full = (wgray == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
  // commit the word on an accepted write.
  always_ff @(posedge wr_clk)
    if (wr_en & ~wr_full) mem[wbin[AW-1:0]] <= wr_data;

  // ---- read pointer + empty ------------------------------------------------
  assign rbin_nxt  = rbin + {{AW{1'b0}}, (rd_en & ~rd_empty)};
  assign rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;
  always_ff @(posedge rd_clk or negedge rd_rst_n)
    if (!rd_rst_n) begin rbin <= '0; rgray <= '0; end
    else           begin rbin <= rbin_nxt; rgray <= rgray_nxt; end
  // EMPTY: read Gray caught up to the synced write Gray.
  assign rd_empty = (rgray == rq2_wgray);
  assign rd_data  = mem[rbin[AW-1:0]];   // FWFT: head always on the bus when !empty

  // ---- 2-flop pointer synchronizers ----------------------------------------
  always_ff @(posedge wr_clk or negedge wr_rst_n)
    if (!wr_rst_n) begin wq1_rgray <= '0; wq2_rgray <= '0; end
    else           begin wq1_rgray <= rgray; wq2_rgray <= wq1_rgray; end
  always_ff @(posedge rd_clk or negedge rd_rst_n)
    if (!rd_rst_n) begin rq1_wgray <= '0; rq2_wgray <= '0; end
    else           begin rq1_wgray <= wgray; rq2_wgray <= rq1_wgray; end

`ifndef SYNTHESIS
  // never write a full FIFO / read an empty one (the bridge must honor the flags).
  wr_no_overflow:  assert property (@(posedge wr_clk) disable iff (!wr_rst_n)
      !(wr_en && wr_full));
  rd_no_underflow: assert property (@(posedge rd_clk) disable iff (!rd_rst_n)
      !(rd_en && rd_empty));
`endif

endmodule : ven_cdc_afifo
