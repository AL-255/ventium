// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_axi_cdc.sv — clock-domain bridge between ven_l1d and ven_axi_master (P1-3).
//
// The dual-clock L1/AXI build (+VEN_AXI_CDC) runs ven_l1d (and the whole core) in
// core_clk — the slow, Fmax-limited PL domain — and ven_axi_master + the AXI4 link to
// the PS DDR in axi_clk, a faster MMCM clock to S_AXI_HPC0. This module bridges the
// WORD-granular backing port between the two using ONE primitive: ven_cdc_afifo.
//
//   ven_l1d.m_*  (core_clk)            ven_axi_master.m_*  (axi_clk)
//        │  creq/cwe/caddr/cwdata/cwstrb     ▲  areq/awe/aaddr/awdata/awstrb
//        ▼                                   │
//   [ cmd afifo  core→axi ]  ──────────►  pop, drive the AXI transaction
//        ▲  crdata/cack                      │  a_ack/a_rdata (one per AXI beat / B)
//        │                                   ▼
//   [ rsp afifo  axi→core ]  ◄──────────  push one entry per ack
//
// The backing port is SINGLE-OUTSTANDING (ven_l1d issues one line fill OR one write-
// through and waits — fpga/L1_AXI_DESIGN.md §1; ven_axi_master's no_rw_overlap SVA).
// So exactly one command is in flight: the command afifo never holds >1, and the
// response afifo holds at most LINE_BEATS (the 8 read beats, if axi_clk outruns the
// slow core drain) — RSP_DEPTH ≥ LINE_BEATS, rounded up to a power of two.
//
// Ack semantics preserved EXACTLY (so ven_l1d / ven_axi_master are untouched):
//   * read fill: ven_l1d wants 8 acks, in ascending word order, each with that word
//     on the bus the cycle it sees the ack. The AXI INCR burst returns beats in
//     ascending order; the rsp afifo is FIFO-ordered and FWFT, so the Nth core-side
//     pop hands word N exactly when ven_l1d's fw==N. Bubbles are fine (ven_l1d holds).
//   * write: ven_l1d wants ONE ack (on BVALID). The rsp afifo carries one entry.
//
// bus_err (ven_axi_master, axi domain) is a STICKY LEVEL → a 2-flop level synchronizer
// brings it to the core domain for the core's bus_err→S_HALT override (no pulse to
// lose). All resets in are already domain-synchronized by ventium_l1_axi.

module ven_axi_cdc #(
    parameter int unsigned LINE_BEATS = 8,
    parameter int          CMD_DEPTH  = 4,         // single-outstanding; power of two
    parameter int          RSP_DEPTH  = 16         // ≥ LINE_BEATS; power of two
) (
    input  logic        core_clk,
    input  logic        core_rst_n,                // synchronized in ventium_l1_axi
    input  logic        axi_clk,
    input  logic        axi_rst_n,                 // synchronized in ventium_l1_axi

    // ---- core side: SLAVE of ven_l1d's backing master (core_clk) --------------
    input  logic        c_req,
    input  logic        c_we,
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wstrb,
    output logic [31:0] c_rdata,
    output logic        c_ack,
    output logic        bus_err,                   // sticky fault, synced to core_clk

    // ---- axi side: MASTER toward ven_axi_master's backing slave (axi_clk) ------
    output logic        a_req,
    output logic        a_we,
    output logic [31:0] a_addr,
    output logic [31:0] a_wdata,
    output logic [3:0]  a_wstrb,
    input  logic [31:0] a_rdata,
    input  logic        a_ack,
    input  logic        a_bus_err                  // ven_axi_master.bus_err (axi_clk)
);

  localparam int CMDW = 1 + 32 + 32 + 4;           // {we, addr, wdata, wstrb}
  localparam int CNTW = $clog2(LINE_BEATS) + 1;     // 0..LINE_BEATS

  // ---- command afifo: core (push) -> axi (pop) ------------------------------
  logic            cmd_wr_en, cmd_full, cmd_rd_en, cmd_empty;
  logic [CMDW-1:0] cmd_wr_data, cmd_rd_data;
  ven_cdc_afifo #(.W(CMDW), .DEPTH(CMD_DEPTH)) u_cmd (
      .wr_clk(core_clk), .wr_rst_n(core_rst_n), .wr_en(cmd_wr_en),
      .wr_data(cmd_wr_data), .wr_full(cmd_full),
      .rd_clk(axi_clk),  .rd_rst_n(axi_rst_n),  .rd_en(cmd_rd_en),
      .rd_data(cmd_rd_data), .rd_empty(cmd_empty));

  // ---- response afifo: axi (push) -> core (pop) -----------------------------
  logic        rsp_wr_en, rsp_full, rsp_rd_en, rsp_empty;
  logic [31:0] rsp_wr_data, rsp_rd_data;
  ven_cdc_afifo #(.W(32), .DEPTH(RSP_DEPTH)) u_rsp (
      .wr_clk(axi_clk),  .wr_rst_n(axi_rst_n),  .wr_en(rsp_wr_en),
      .wr_data(rsp_wr_data), .wr_full(rsp_full),
      .rd_clk(core_clk), .rd_rst_n(core_rst_n), .rd_en(rsp_rd_en),
      .rd_data(rsp_rd_data), .rd_empty(rsp_empty));

  // ==========================================================================
  // CORE side: accept one backing transaction, drain its responses to ven_l1d.
  // ==========================================================================
  typedef enum logic { C_IDLE, C_BUSY } cstate_e;
  cstate_e         cst;
  logic [CNTW-1:0] rcnt, rexp;       // responses drained / expected (LINE_BEATS or 1)

  assign cmd_wr_en   = (cst == C_IDLE) && c_req && !cmd_full;
  assign cmd_wr_data = {c_we, c_addr, c_wdata, c_wstrb};
  // hand each FWFT response to ven_l1d as one ack; never over-ack past rexp.
  assign c_ack     = (cst == C_BUSY) && !rsp_empty && (rcnt < rexp);
  assign rsp_rd_en = c_ack;
  assign c_rdata   = rsp_rd_data;

  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin
      cst <= C_IDLE; rcnt <= '0; rexp <= CNTW'(1);
    end else unique case (cst)
      C_IDLE: if (c_req && !cmd_full) begin
                rexp <= c_we ? CNTW'(1) : CNTW'(LINE_BEATS);
                rcnt <= '0;
                cst  <= C_BUSY;
              end
      C_BUSY: if (c_ack) begin
                rcnt <= rcnt + CNTW'(1);
                // Complete ON the last response and return to C_IDLE next cycle —
                // do NOT wait for !c_req. ven_l1d holds m_req CONTINUOUSLY across
                // back-to-back transactions (e.g. FNSAVE's 27 sequential stores: it
                // re-asserts the next request the cycle after this ack, so c_req
                // never drops); waiting for !c_req would DEADLOCK. This mirrors
                // ven_axi_master's own re-sample timing (it returns to W_IDLE/R_IDLE
                // one cycle after m_ack and re-samples m_req for the next access) —
                // by next cycle ven_l1d has advanced past this transaction (the core
                // latched c_ack), so C_IDLE samples the NEXT request, never a stale
                // re-presentation of this one. (The same core invariant that makes
                // the direct ven_axi_master correct — 77/77 — makes this correct.)
                if (rcnt == rexp - CNTW'(1)) cst <= C_IDLE;
              end
      default: cst <= C_IDLE;
    endcase

  // ==========================================================================
  // AXI side: pop one command, run it through ven_axi_master, push each beat back.
  // ==========================================================================
  typedef enum logic { A_IDLE, A_BUSY } astate_e;
  astate_e         ast;
  logic [CNTW-1:0] acnt, aexp;
  logic            areq_q, awe_q;
  logic [31:0]     aaddr_q, awdata_q;
  logic [3:0]      awstrb_q;

  assign cmd_rd_en   = (ast == A_IDLE) && !cmd_empty;
  assign rsp_wr_en   = (ast == A_BUSY) && a_ack;     // one push per ven_axi_master ack
  assign rsp_wr_data = a_rdata;
  assign a_req   = areq_q;
  assign a_we    = awe_q;
  assign a_addr  = aaddr_q;
  assign a_wdata = awdata_q;
  assign a_wstrb = awstrb_q;

  always_ff @(posedge axi_clk or negedge axi_rst_n)
    if (!axi_rst_n) begin
      ast <= A_IDLE; areq_q <= 1'b0; acnt <= '0; aexp <= CNTW'(1);
      awe_q <= 1'b0; aaddr_q <= '0; awdata_q <= '0; awstrb_q <= '0;
    end else unique case (ast)
      A_IDLE: if (!cmd_empty) begin
                {awe_q, aaddr_q, awdata_q, awstrb_q} <= cmd_rd_data;
                aexp   <= cmd_rd_data[CMDW-1] ? CNTW'(1) : CNTW'(LINE_BEATS);
                acnt   <= '0;
                areq_q <= 1'b1;
                ast    <= A_BUSY;
              end
      A_BUSY: if (a_ack) begin
                acnt <= acnt + CNTW'(1);
                // drop a_req ON the last ack so ven_axi_master, returning to its IDLE
                // the same edge, sees a_req=0 next cycle and does NOT re-trigger.
                if (acnt == aexp - CNTW'(1)) begin
                  areq_q <= 1'b0;
                  ast    <= A_IDLE;
                end
              end
      default: ast <= A_IDLE;
    endcase

  // ---- bus_err: sticky level, 2-flop sync axi_clk -> core_clk ----------------
  (* ASYNC_REG = "TRUE" *) logic be_meta, be_sync;
  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin be_meta <= 1'b0; be_sync <= 1'b0; end
    else             begin be_meta <= a_bus_err; be_sync <= be_meta; end
  assign bus_err = be_sync;

`ifndef SYNTHESIS
  // single-outstanding: the core must never WANT to push while the command afifo is
  // full. Assert the UNGATED intent (cmd_wr_en is self-gated on !cmd_full, so
  // !(cmd_wr_en && cmd_full) would be a vacuous tautology that can never fire) — this
  // form actually catches a future single-outstanding violation (a 2nd push path / a
  // shrunk CMD_DEPTH) that would drop a command and hang ven_l1d.
  cmd_no_full:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      !((cst == C_IDLE) && c_req && cmd_full));
  // the response afifo (depth ≥ LINE_BEATS) must never overflow under single-out.
  rsp_no_full:  assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
      !(rsp_wr_en && rsp_full));
  // the latched command must be stable for ven_axi_master to sample — it changes ONLY
  // on the A_IDLE->A_BUSY load edge, so require stability across CONSECUTIVE A_BUSY
  // cycles (not the entry edge, where aaddr_q is legitimately being loaded).
  areq_stable:  assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
      ((ast == A_BUSY) && $past(ast == A_BUSY)) |-> $stable(aaddr_q) && $stable(awe_q));
`endif

endmodule : ven_axi_cdc
