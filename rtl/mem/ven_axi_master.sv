// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_axi_master.sv — ven_l1d backing port -> AXI4 master (P1-1 step 2).
//
// ven_l1d's backing port (m_*) is WORD-granular: on a line fill it holds m_req
// and walks 8 sequential, line-aligned word addresses, one m_ack per word
// (ven_l1d.sv:99,151,158 — fw advances on EVERY posedge where m_ack==1, with NO
// per-beat valid and NO backpressure); on a write-through it presents one word
// with byte strobes. This module converts that word stream into AXI4 transactions
// to the PS DDR (S_AXI_HPC0_FPD):
//   * READ  (m_we=0): ven_l1d only ever reads during a FILL, and a fill is ALWAYS
//     a full 32-byte line (8 words, base-aligned, ascending) — so a backing read is
//     COALESCED into ONE AXI INCR burst of LINE_BEATS beats (ARLEN=7). Each
//     returned R beat is handed back as ONE m_ack + m_rdata, in order — exactly the
//     word ven_l1d's fill counter `fw` expects. The single true m_ack rule is
//     `m_ack = (RVALID && RREADY)`: a new word this cycle, m_rdata == that word,
//     m_ack=0 on any bubble cycle (fw then holds and resumes on the next beat).
//   * WRITE (m_we=1): a single-beat AXI write (AWLEN=0), WSTRB = m_wstrb verbatim
//     (32-bit bus, no lane shift). m_ack pulses on BVALID -> ven_l1d's write-through
//     completes (c_ack follows m_ack combinationally, ven_l1d.sv:112). NEVER ack
//     before BVALID — an early ack lets the core advance with the store still in
//     flight = a lost write.
//
// Address remap: the L1 tags/data use the x86 PHYSICAL address; the DDR address is
//   ddr_addr = REMAP_BASE + (phys & ADDR_MASK)  — the whole x86 phys space lands in
// one reserved DDR carveout (REMAP_BASE/ADDR_MASK = the PetaLinux reserved-memory
// node's base/size). The remap is done in ADDR_W width (no 32-bit truncation), and
// REMAP_BASE must be 32-byte aligned so an INCR8 burst never crosses a 4KiB page.
//
// Single clock domain (CDC_BYPASS=1, the clean low-risk bring-up): core_clk ==
// axi_clk == the PS PL clock. The async dual-clock CDC variant (core clk vs a
// faster AXI clk via MMCM, an in-repo clean-license 2-FF-Gray async FIFO) is a
// later optimization — a single PL clock to S_AXI_HPC0 is the standard first step.
//
// AXI compliance invariants (the load-bearing ones):
//   * every *VALID is driven from REGISTERED state, never combinational on its
//     *READY (a VALID<-READY comb path deadlocks vs a slave doing READY<-VALID);
//     RREADY/BREADY MAY be combinational on state.
//   * once asserted, *VALID + all its payload hold stable until the handshake.
//   * AW and W handshake INDEPENDENTLY (decoupled done-latches) — never gate WVALID
//     on AWREADY (classic write deadlock vs a W-before-AW slave).

module ven_axi_master #(
    parameter int unsigned LINE_BEATS = 8,                 // 32B line / 4B word
    parameter int          ADDR_W     = 40,                // PS8 HPC0 master addr
    parameter logic [39:0] REMAP_BASE = 40'h00_0000_0000,  // DDR carveout base
    parameter logic [31:0] ADDR_MASK  = 32'hFFFF_FFFF,     // phys window mask
    parameter logic [3:0]  AXI_ID     = 4'd0
) (
    input  logic        core_clk,
    input  logic        core_rst_n,
    input  logic        axi_clk,        // == core_clk in the CDC_BYPASS build
    input  logic        axi_rst_n,      // == core_rst_n in the CDC_BYPASS build

    // ---- backing slave port (driven by ven_l1d's m_* master) ------------------
    input  logic        m_req,
    input  logic        m_we,
    input  logic [31:0] m_addr,
    input  logic [31:0] m_wdata,
    input  logic [3:0]  m_wstrb,
    output logic [31:0] m_rdata,
    output logic        m_ack,

    // ---- AXI4 master port (-> S_AXI_HPC0_FPD, 32-bit data) --------------------
    // write address channel
    output logic [3:0]        m_axi_awid,
    output logic [ADDR_W-1:0] m_axi_awaddr,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awlock,
    output logic [3:0]        m_axi_awcache,
    output logic [2:0]        m_axi_awprot,
    output logic [3:0]        m_axi_awqos,
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,
    // write data channel
    output logic [31:0]       m_axi_wdata,
    output logic [3:0]        m_axi_wstrb,
    output logic              m_axi_wlast,
    output logic              m_axi_wvalid,
    input  logic              m_axi_wready,
    // write response channel
    input  logic [3:0]        m_axi_bid,
    input  logic [1:0]        m_axi_bresp,
    input  logic              m_axi_bvalid,
    output logic              m_axi_bready,
    // read address channel
    output logic [3:0]        m_axi_arid,
    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arlock,
    output logic [3:0]        m_axi_arcache,
    output logic [2:0]        m_axi_arprot,
    output logic [3:0]        m_axi_arqos,
    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,
    // read data channel
    input  logic [3:0]        m_axi_rid,
    input  logic [31:0]       m_axi_rdata,
    input  logic [1:0]        m_axi_rresp,
    input  logic              m_axi_rlast,
    input  logic              m_axi_rvalid,
    output logic              m_axi_rready
);

`ifndef SYNTHESIS
  // elaboration guards: convert two silent-corruption bugs into build failures.
  initial begin
    if (REMAP_BASE[4:0] != 5'd0)
      $fatal(1, "ven_axi_master: REMAP_BASE must be 32-byte aligned (INCR8 4KiB rule)");
    if (LINE_BEATS != 8)
      $fatal(1, "ven_axi_master: LINE_BEATS must be 8 (ven_l1d 32B line)");
  end
`endif

  // remap an x86 physical address into the reserved DDR window, in ADDR_W width.
  function automatic logic [ADDR_W-1:0] remap(input logic [31:0] a);
    remap = REMAP_BASE + ADDR_W'(a & ADDR_MASK);
  endfunction

  // ---- READ FSM (coalesced INCR line fill) ----------------------------------
  typedef enum logic [1:0] { R_IDLE, R_AR, R_DATA } rstate_e;
  rstate_e          rst;
  logic [ADDR_W-1:0] araddr_q;     // line-aligned burst base (registered, stable)

  // ---- WRITE FSM (single-beat write-through, decoupled AW/W) -----------------
  typedef enum logic [1:0] { W_IDLE, W_RUN, W_RESP } wstate_e;
  wstate_e          wst;
  logic [ADDR_W-1:0] awaddr_q;
  logic [31:0]       wdata_q;
  logic [3:0]        wstrb_q;
  logic              aw_done, w_done;  // independent handshake latches

  // ---- AXI combinational drive ----------------------------------------------
  always_comb begin
    // read address channel — burst base forced 32B-aligned (never crosses 4KiB).
    m_axi_arid    = AXI_ID;
    m_axi_araddr  = araddr_q;
    m_axi_arlen   = 8'(LINE_BEATS - 1);   // LINE_BEATS-beat INCR burst
    m_axi_arsize  = 3'b010;               // 4 bytes/beat
    m_axi_arburst = 2'b01;               // INCR
    m_axi_arlock  = 1'b0;
    m_axi_arcache = 4'b1111;             // write-back R/W-allocate (HPC0 coherent)
    m_axi_arprot  = 3'b000;
    m_axi_arqos   = 4'd0;
    m_axi_arvalid = (rst == R_AR);
    m_axi_rready  = (rst == R_DATA);

    // write address channel — single 4-byte beat at the raw (un-line-aligned) addr.
    m_axi_awid    = AXI_ID;
    m_axi_awaddr  = awaddr_q;
    m_axi_awlen   = 8'd0;
    m_axi_awsize  = 3'b010;
    m_axi_awburst = 2'b01;
    m_axi_awlock  = 1'b0;
    m_axi_awcache = 4'b1111;
    m_axi_awprot  = 3'b000;
    m_axi_awqos   = 4'd0;
    m_axi_awvalid = (wst == W_RUN) && !aw_done;
    // write data channel
    m_axi_wdata   = wdata_q;
    m_axi_wstrb   = wstrb_q;
    m_axi_wlast   = 1'b1;                 // single-beat write
    m_axi_wvalid  = (wst == W_RUN) && !w_done;
    // write response channel
    m_axi_bready  = (wst == W_RESP);

    // backing response: a read beat hands RDATA back as one m_ack; the write acks
    // on BVALID. m_rdata is the live RDATA (captured by ven_l1d when m_ack pulses).
    m_rdata = m_axi_rdata;
    m_ack   = ((rst == R_DATA) && m_axi_rvalid && m_axi_rready) ||
              ((wst == W_RESP) && m_axi_bvalid);
  end

  // ---- READ sequencing -------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      rst <= R_IDLE; araddr_q <= '0;
    end else begin
      unique case (rst)
        R_IDLE: if (m_req && !m_we) begin
                  // a backing read == a full line fill: latch the 32B-aligned base.
                  araddr_q <= remap({m_addr[31:5], 5'd0});
                  rst <= R_AR;
                end
        R_AR:   if (m_axi_arready) rst <= R_DATA;             // AR accepted
        R_DATA: if (m_axi_rvalid && m_axi_rlast) rst <= R_IDLE; // burst complete
        default: rst <= R_IDLE;
      endcase
    end
  end

  // ---- WRITE sequencing ------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      wst <= W_IDLE; awaddr_q <= '0; wdata_q <= 32'd0; wstrb_q <= 4'd0;
      aw_done <= 1'b0; w_done <= 1'b0;
    end else begin
      unique case (wst)
        W_IDLE: if (m_req && m_we) begin
                  awaddr_q <= remap(m_addr);
                  wdata_q  <= m_wdata; wstrb_q <= m_wstrb;
                  aw_done  <= 1'b0;    w_done  <= 1'b0;
                  wst <= W_RUN;
                end
        W_RUN: begin
          // AW and W complete INDEPENDENTLY (either order) — never coupled.
          if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
          if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
              (w_done  || (m_axi_wvalid  && m_axi_wready)))
            wst <= W_RESP;
        end
        W_RESP: if (m_axi_bvalid) wst <= W_IDLE;  // m_ack pulsed (comb) this cycle
        default: wst <= W_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // ---- bound protocol checks (VALID stability, burst legality, ordering) -----
  // VALID held with stable payload until the handshake.
  ar_stable: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_arvalid && !m_axi_arready) |=> (m_axi_arvalid && $stable(m_axi_araddr)
                                             && $stable(m_axi_arlen)));
  aw_stable: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_awvalid && !m_axi_awready) |=> (m_axi_awvalid && $stable(m_axi_awaddr)));
  // W payload stable independent of AW (decoupling check).
  w_stable:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_wvalid && !m_axi_wready) |=> (m_axi_wvalid && $stable(m_axi_wdata)
                                           && $stable(m_axi_wstrb) && $stable(m_axi_wlast)));
  // every read-burst base is 32B-aligned and the 32B burst never crosses 4KiB.
  ar_align:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> (m_axi_araddr[4:0] == 5'd0));
  ar_4k:     assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> ((13'(m_axi_araddr[11:0]) + 13'(LINE_BEATS*4)) <= 13'h1000));
  // no AR while a write is outstanding (single-outstanding in-order guarantee).
  no_rw_overlap: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      !(m_axi_arvalid && (wst != W_IDLE)));
`endif

  // lint sinks: RID/RRESP/BID/BRESP not consulted (single in-flight, AxID=0); the
  // axi_clk/axi_rst_n ports are tied to the core domain in the CDC_BYPASS build.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, m_axi_bid, m_axi_bresp, m_axi_rid, m_axi_rresp,
                   m_axi_rid, axi_clk, axi_rst_n};
  // verilator lint_on UNUSED

endmodule : ven_axi_master
