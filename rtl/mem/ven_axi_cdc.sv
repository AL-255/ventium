`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
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
//        │  + crd_narrow/crd_size             │  + ard_narrow/ard_size
//        ▼                                   │
//   [ cmd afifo  core→axi ]  ──────────►  pop, drive the AXI transaction
//        ▲  crdata/cack                      │  a_ack/a_rdata (one per AXI beat / B)
//        │                                   ▼
//   [ rsp afifo  axi→core ]  ◄──────────  push one entry per ack
//
// The backing port is SINGLE-OUTSTANDING (ven_l1d issues one line fill OR one write-
// through and waits — fpga/L1_AXI_DESIGN.md §1; ven_axi_master's no_rw_overlap SVA).
// So exactly one command is in flight: the command afifo never holds >1, and the
// response afifo holds at most LINE_BEATS entries (an 8-beat fill's read beats, if
// axi_clk outruns the slow core drain; a narrow read is 1-2 beats — strictly fewer)
// — RSP_DEPTH ≥ LINE_BEATS, rounded up to a power of two.
//
// REVIEW_Aug3 C-01: the command record carries the H-11 NARROW-READ bits with the
// rest of the request. They used to cross OUTSIDE the FIFO — ven_axi_master consumed
// b_rd_narrow combinationally while the request it described was still queued in the
// core clock domain: a metadata/request race (the master could sample the bits of the
// PREVIOUS or the NEXT access) AND a beat-count disagreement, since both FSMs here
// hard-coded LINE_BEATS responses for every read while the master correctly burst
// only 1-2 beats (the core side then waited forever for 6-7 responses that never
// exist). Now the expected-response counters on BOTH sides are derived from the
// command record itself, and the a-side bits presented to ven_axi_master are
// REGISTERS latched from the same FIFO word as the address — one atomic record.
//
// Ack semantics preserved EXACTLY (so ven_l1d / ven_axi_master are untouched):
//   * read fill: ven_l1d wants 8 acks in its circular fill order (the faulting
//     dword, then the rest of the line after wrap), each with that word on the bus
//     the cycle it sees the ack. The AXI INCR8/WRAP8 response and the rsp afifo are
//     FIFO-ordered and FWFT, so the Nth core-side pop hands the intended circular
//     word exactly when ven_l1d's fw==N. Bubbles are fine (ven_l1d holds).
//   * write: ven_l1d wants ONE ack (on BVALID). The rsp afifo carries one entry.
//
// bus_err (ven_axi_master, axi domain) is a STICKY LEVEL → a 2-flop level synchronizer
// brings it to the core domain for the core's bus_err→S_HALT override (no pulse to
// lose).  A fault is terminal: the AXI side drops its held backing request but lets
// ven_axi_master drain the AXI transaction, while the core side stops delivering
// partial FIFO data.  Neither side manufactures a completion/data word merely to
// make a failed fill look complete; the existing coupled external reset clears both
// FIFOs and releases the terminal states. All resets in are already domain-synchronized
// by ventium_l1_axi.

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
    // REVIEW_Aug3 C-01: the H-11 narrow-read attributes travel INSIDE the command
    // record (see the header): c_rd_narrow = this read is a narrow device access,
    // not an 8-beat line fill. REVIEW1_Aug3 R2-H01: c_rd_size is the piece's exact
    // ARSIZE (0=1B, 1=2B, 2=4B) -- each narrow piece is its OWN single-beat
    // transaction, so the response count for a narrow read is 1 like a write's.
    input  logic        c_rd_narrow,
    input  logic [1:0]  c_rd_size,
    output logic [31:0] c_rdata,
    output logic        c_ack,
    output logic        bus_err,                   // sticky fault, synced to core_clk

    // ---- axi side: MASTER toward ven_axi_master's backing slave (axi_clk) ------
    output logic        a_req,
    output logic        a_we,
    output logic [31:0] a_addr,
    output logic [31:0] a_wdata,
    output logic [3:0]  a_wstrb,
    // C-01: the narrow bits, latched from the SAME command-FIFO word as a_addr, so
    // ven_axi_master never samples read shape from a different access (the race the
    // direct b_rd_narrow connection had). Valid while a_req is asserted.
    output logic        a_rd_narrow,
    output logic [1:0]  a_rd_size,
    input  logic [31:0] a_rdata,
    input  logic        a_ack,
    input  logic        a_bus_err                  // ven_axi_master.bus_err (axi_clk)
);

  // C-01: the command record is one atomic word: rd_size is bits [1:0], rd_narrow
  // bit 2 (R2-H01), so the a-side expected-beat count decodes straight off the word.
  localparam int CMDW = 1 + 32 + 32 + 4 + 1 + 2;  // {we, addr, wdata, wstrb, rd_narrow, rd_size}
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
  typedef enum logic [1:0] { C_IDLE, C_BUSY, C_FAULT } cstate_e;
  cstate_e         cst;
  logic [CNTW-1:0] rcnt, rexp;       // responses drained / expected (see C_IDLE)

  // A synced fatal fault is terminal for this request path.  Do not let a held
  // ven_l1d request re-enter the command FIFO, and do not pass already-queued
  // pre-fault response words to the L1 as if the failed backing transfer completed.
  assign cmd_wr_en   = (cst == C_IDLE) && c_req && !cmd_full && !bus_err;
  assign cmd_wr_data = {c_we, c_addr, c_wdata, c_wstrb, c_rd_narrow, c_rd_size};
  // hand each FWFT response to ven_l1d as one ack; never over-ack past rexp.
  assign c_ack     = (cst == C_BUSY) && !bus_err && !rsp_empty && (rcnt < rexp);
  assign rsp_rd_en = c_ack;
  assign c_rdata   = rsp_rd_data;

  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin
      cst <= C_IDLE; rcnt <= '0; rexp <= CNTW'(1);
    end else unique case (cst)
      C_IDLE: if (bus_err) begin
                cst <= C_FAULT;
              end else if (c_req && !cmd_full) begin
                // C-01: the expected response count comes from the REQUEST ITSELF,
                // not the constant LINE_BEATS: a write acks once (BVALID); a narrow
                // read is 1 or 2 beats by its straddle bit; a cacheable fill is a
                // full line. The a-side decodes the same record, so the two FSMs and
                // ven_axi_master cannot disagree about the burst length.
                // R2-H01: a narrow piece is ONE single-beat transaction, like a
                // write; only a cacheable fill is a full line.
                rexp <= (c_we || c_rd_narrow) ? CNTW'(1) : CNTW'(LINE_BEATS);
                rcnt <= '0;
                cst  <= C_BUSY;
              end
      C_BUSY: if (bus_err) begin
                cst <= C_FAULT;
              end else if (c_ack) begin
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
      // The error level is sticky and the processor halts on it.  Hold the
      // bridge terminal until the coupled reset flushes both asynchronous FIFOs;
      // returning to IDLE or generating dummy responses here could turn a failed
      // line fill into architecturally visible data.
      C_FAULT: cst <= C_FAULT;
      default: cst <= C_IDLE;
    endcase

  // ==========================================================================
  // AXI side: pop one command, run it through ven_axi_master, push each beat back.
  // ==========================================================================
  typedef enum logic [1:0] { A_IDLE, A_BUSY, A_FAULT } astate_e;
  astate_e         ast;
  logic [CNTW-1:0] acnt, aexp;
  logic            areq_q, awe_q;
  logic [31:0]     aaddr_q, awdata_q;
  logic [3:0]      awstrb_q;
  logic            ard_narrow_q;    logic [1:0] ard_size_q;   // C-01/R2-H01: latched with the command

  // Once ven_axi_master reports its sticky fatal level, leave any late command in
  // the FIFO for the coupled reset rather than popping/relaunching it.  The master
  // itself continues draining already accepted AXI R/B traffic with its protocol
  // signals intact; this bridge merely stops forwarding it as architectural data.
  assign cmd_rd_en   = (ast == A_IDLE) && !cmd_empty && !a_bus_err;
  assign rsp_wr_en   = (ast == A_BUSY) && a_ack && !a_bus_err; // one good ack per response
  assign rsp_wr_data = a_rdata;
  assign a_req   = areq_q;
  assign a_we    = awe_q;
  assign a_addr  = aaddr_q;
  assign a_wdata = awdata_q;
  assign a_wstrb = awstrb_q;
  assign a_rd_narrow   = ard_narrow_q;               // C-01: same-record read shape
  assign a_rd_size     = ard_size_q;

  always_ff @(posedge axi_clk or negedge axi_rst_n)
    if (!axi_rst_n) begin
      ast <= A_IDLE; areq_q <= 1'b0; acnt <= '0; aexp <= CNTW'(1);
      awe_q <= 1'b0; aaddr_q <= '0; awdata_q <= '0; awstrb_q <= '0;
      ard_narrow_q <= 1'b0; ard_size_q <= 2'd0;
    end else unique case (ast)
      A_IDLE: if (a_bus_err) begin
                areq_q <= 1'b0;
                ast    <= A_FAULT;
              end else if (!cmd_empty) begin
                {awe_q, aaddr_q, awdata_q, awstrb_q, ard_narrow_q, ard_size_q} <= cmd_rd_data;
                // C-01/R2-H01: expected acks decoded from the SAME FIFO word (bit
                // CMDW-1 = we, bit 2 = rd_narrow) — mirroring the c-side rexp decode
                // so both ends count the burst the master will actually run.
                aexp   <= (cmd_rd_data[CMDW-1] || cmd_rd_data[2]) ? CNTW'(1)
                                                                : CNTW'(LINE_BEATS);
                acnt   <= '0;
                areq_q <= 1'b1;
                ast    <= A_BUSY;
              end
      A_BUSY: if (a_bus_err) begin
                // The failed beat is deliberately NOT an a_ack.  Drop the bridge's
                // request so the master cannot re-trigger after it drains, but do
                // not reset the master/FIFOs or withdraw any AXI channel handshake.
                areq_q <= 1'b0;
                acnt   <= '0;
                ast    <= A_FAULT;
              end else if (a_ack) begin
                acnt <= acnt + CNTW'(1);
                // drop a_req ON the last ack so ven_axi_master, returning to its IDLE
                // the same edge, sees a_req=0 next cycle and does NOT re-trigger.
                if (acnt == aexp - CNTW'(1)) begin
                  areq_q <= 1'b0;
                  ast    <= A_IDLE;
                end
              end
      A_FAULT: begin
                 areq_q <= 1'b0;
                 ast    <= A_FAULT;
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
      !(!bus_err && (cst == C_IDLE) && c_req && cmd_full));
  // the response afifo (depth ≥ LINE_BEATS) must never overflow under single-out.
  rsp_no_full:  assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
      !(rsp_wr_en && rsp_full));
  // the latched command must be stable for ven_axi_master to sample — it changes ONLY
  // on the A_IDLE->A_BUSY load edge, so require stability across CONSECUTIVE A_BUSY
  // cycles (not the entry edge, where aaddr_q is legitimately being loaded). C-01:
  // the narrow bits are part of the same record and get the same guarantee — the
  // master reads them while deciding the burst length, mid-transaction.
  areq_stable:  assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
      ((ast == A_BUSY) && $past(ast == A_BUSY)) |-> $stable(aaddr_q) && $stable(awe_q)
                                                && $stable(ard_narrow_q) && $stable(ard_size_q));
  // A terminal fault may leave partial words resident in the asynchronous FIFOs,
  // but it must never turn one into a fabricated backing completion.  The external
  // coupled reset is the only recovery path, so both bridge FSMs remain quiet until
  // that reset rather than re-entering the normal request protocol.
  core_fault_quiet: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      bus_err |=> ((cst == C_FAULT) && !c_ack));
  axi_fault_quiet: assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
      a_bus_err |=> ((ast == A_FAULT) && !a_req && !rsp_wr_en));
`endif

endmodule : ven_axi_cdc
