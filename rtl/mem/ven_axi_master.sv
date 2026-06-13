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
    parameter logic [3:0]  AXI_ID     = 4'd0,
    // #34: per-transaction watchdog. If a read/write makes no progress for WATCHDOG
    // core clocks (a stuck DDR/bridge), the FSM ABORTS — synthesizes the acks ven_l1d
    // expects (so the core never deadlocks) + raises bus_err. Default huge (a normal
    // line fill is <~50 clocks); tests override it small.
    parameter int unsigned WATCHDOG = 1024
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
    output logic        bus_err,        // #34: sticky FATAL fault (timeout or SLVERR/DECERR)

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
  logic [7:0]        r_beat;       // accepted-R-beat counter (exit on count, not RLAST)
  logic              rresp_err;    // sticky: a read beat returned non-OKAY RRESP
  logic              bresp_err;    // sticky: a write returned non-OKAY BRESP
  logic              wd_err_r;     // sticky: a READ watchdog timeout aborted (read-FF driven)
  logic              wd_err_w;     // sticky: a WRITE watchdog timeout aborted (write-FF driven)
  logic [15:0]       r_wd, w_wd;   // #34 read/write watchdog cycle counters (since last progress)

  // ---- WRITE FSM (write-through, decoupled AW/W; up to 2 word beats) ----------
  // A core store is byte-addressed: the byte at m_addr is lane 0 of m_wstrb/m_wdata.
  // Mapped onto a 32-bit AXI bus it occupies lanes [boff .. boff+nbytes-1]; when that
  // range spills past lane 3 (an unaligned 16/32-bit store, e.g. a dword to ..0x..2)
  // the store straddles TWO 32-bit words and must be issued as TWO single-beat AXI
  // writes (word A = m_addr&~3, word B = +4). The core is acked only after BOTH land,
  // so ven_l1d's c_ack (= m_ack) completes the store exactly once. SeaBIOS POST does
  // these unaligned stores; the byte-addressed sim BFM masked the bug on silicon.
  typedef enum logic [1:0] { W_IDLE, W_RUN, W_RESP } wstate_e;
  wstate_e          wst;
  logic [ADDR_W-1:0] awaddr_q;       // current beat's word-aligned AXI address
  logic [31:0]       wdata_q;        // current beat's data (lane-shifted)
  logic [3:0]        wstrb_q;        // current beat's strobe (lane-shifted)
  logic [ADDR_W-1:0] awaddr2_q;      // beat B address (m_addr&~3 + 4)
  logic [31:0]       wdata2_q;       // beat B data  (high 32 of the 64-bit shift)
  logic [3:0]        wstrb2_q;       // beat B strobe (high 4  of the 8-bit  shift)
  logic              xword_q;        // 1 = the store straddles a word -> need beat B
  logic              wbeat;          // 0 = beat A in flight, 1 = beat B in flight
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

    // backing response: a read beat hands RDATA back as one m_ack; the write acks on
    // BVALID. On a watchdog timeout the AXI handshake is HELD (a master cannot retract
    // VALID — AXI has no cancel), bus_err is raised, and the core's bus_err->S_HALT
    // override abandons the stuck access + halts (the PS then resets). No protocol-
    // violating abort, no drain.
    m_rdata = m_axi_rdata;
    // ack the core write only after the FINAL beat (beat A of an aligned store, or
    // beat B of a straddling one) — a per-beat ack would complete the core's store
    // after only the first word landed.
    m_ack   = ((rst == R_DATA) && m_axi_rvalid && m_axi_rready) ||
              ((wst == W_RESP) && m_axi_bvalid && (!xword_q || wbeat));
    bus_err = wd_err_r | wd_err_w | rresp_err | bresp_err;  // #34 sticky fatal-fault to core
  end

  // ---- READ sequencing -------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      rst <= R_IDLE; araddr_q <= '0; r_beat <= 8'd0; rresp_err <= 1'b0;
      r_wd <= 16'd0; wd_err_r <= 1'b0;
    end else begin
      unique case (rst)
        R_IDLE: if (m_req && !m_we) begin
                  // a backing read == a full line fill: latch the 32B-aligned base.
                  araddr_q <= remap({m_addr[31:5], 5'd0});
                  r_beat <= 8'd0; rresp_err <= 1'b0; r_wd <= 16'd0;
                  rst <= R_AR;
                end
        R_AR:   if (m_axi_arready) begin rst <= R_DATA; r_wd <= 16'd0; end // AR accepted
                // #34 watchdog: a stall of WATCHDOG cycles with no progress -> raise
                // the sticky fault (bus_err) but HOLD arvalid (AXI: VALID can't retract).
                else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;
                else r_wd <= r_wd + 16'd1;
        R_DATA: if (m_axi_rvalid && m_axi_rready) begin       // beat accepted (progress)
                  // DEFENSIVE: exit on the BEAT COUNT vs ARLEN, NOT a (possibly
                  // mis-asserted) RLAST — a non-compliant slave's early RLAST then
                  // cannot freeze ven_l1d's fill mid-line. Identical timing for a
                  // compliant slave (RLAST lands exactly at r_beat==LINE_BEATS-1, the
                  // rlast_align SVA below checks it). Sticky-flag a non-OKAY RRESP.
                  if (m_axi_rresp != 2'b00)        rresp_err <= 1'b1;
                  if (r_beat == 8'(LINE_BEATS-1))  rst <= R_IDLE;  // burst complete
                  r_beat <= r_beat + 8'd1; r_wd <= 16'd0;
                end
                else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;  // #34 stall watchdog
                else r_wd <= r_wd + 16'd1;
        default: rst <= R_IDLE;
      endcase
    end
  end

  // ---- WRITE sequencing ------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      wst <= W_IDLE; awaddr_q <= '0; wdata_q <= 32'd0; wstrb_q <= 4'd0;
      awaddr2_q <= '0; wdata2_q <= 32'd0; wstrb2_q <= 4'd0; xword_q <= 1'b0; wbeat <= 1'b0;
      aw_done <= 1'b0; w_done <= 1'b0; bresp_err <= 1'b0; w_wd <= 16'd0; wd_err_w <= 1'b0;
    end else begin
      unique case (wst)
        W_IDLE: if (m_req && m_we) begin
                  // BYTE-LANE ALIGN (P2 fix): the core's mem port is byte-addressed —
                  // the byte at m_addr sits in LANE 0 of m_wdata/m_wstrb (symmetric with
                  // the read window c_rdata = line[boff*8 +: 32]). A 32-bit AXI write
                  // places byte lane b at the WORD-ALIGNED address + b, so the master
                  // word-aligns awaddr and shifts data/strobes left by m_addr[1:0] bytes
                  // onto the correct lanes. Forwarding the raw byte address + lane-0 data
                  // wrote the WRONG DDR bytes on silicon (the stack / CALL-RET / IVT
                  // coherence failure); the byte-addressed sim BFM masked it.
                  //
                  // 2-BEAT SPLIT (P2b): shift the store into a 64-bit / 8-bit lane field.
                  // The low 32b/4b are beat A (word m_addr&~3); if any strobe spilled into
                  // the high 4b the store straddles the next word, captured as beat B
                  // (word +4). SeaBIOS POST emits such unaligned (16/32-bit) stores.
                  begin
                    automatic logic [63:0] dsh = {32'd0, m_wdata} << {m_addr[1:0], 3'b000};
                    automatic logic [7:0]  ssh = {4'd0, m_wstrb} << m_addr[1:0];
                    awaddr_q  <= remap({m_addr[31:2], 2'b00});
                    wdata_q   <= dsh[31:0];
                    wstrb_q   <= ssh[3:0];
                    awaddr2_q <= remap({m_addr[31:2], 2'b00} + 32'd4);
                    wdata2_q  <= dsh[63:32];
                    wstrb2_q  <= ssh[7:4];
                    xword_q   <= (ssh[7:4] != 4'd0);
                  end
                  wbeat    <= 1'b0;
                  aw_done  <= 1'b0;    w_done  <= 1'b0;  bresp_err <= 1'b0; w_wd <= 16'd0;
                  wst <= W_RUN;
                end
        W_RUN: begin
          // AW and W complete INDEPENDENTLY (either order) — never coupled.
          if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
          if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
              (w_done  || (m_axi_wvalid  && m_axi_wready)))
                                              begin wst <= W_RESP; w_wd <= 16'd0; end
          else if (w_wd >= 16'(WATCHDOG)) wd_err_w <= 1'b1;  // #34 stall watchdog (hold VALID)
          else w_wd <= w_wd + 16'd1;
        end
        W_RESP: if (m_axi_bvalid) begin           // m_ack pulsed (comb) this cycle
                  if (m_axi_bresp != 2'b00) bresp_err <= 1'b1;  // sticky non-OKAY BRESP
                  if (!wbeat && xword_q) begin
                    // straddling store: beat A landed -> issue beat B (next word).
                    awaddr_q <= awaddr2_q; wdata_q <= wdata2_q; wstrb_q <= wstrb2_q;
                    wbeat <= 1'b1; aw_done <= 1'b0; w_done <= 1'b0; w_wd <= 16'd0;
                    wst <= W_RUN;
                  end else begin
                    wst <= W_IDLE;
                  end
                end
                else if (w_wd >= 16'(WATCHDOG)) wd_err_w <= 1'b1;  // #34 stall watchdog
                else w_wd <= w_wd + 16'd1;
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
  // P2b: a store straddling a 32-bit word is now SPLIT into beat A (word) + beat B
  // (word+4). A 4-byte store shifted by at most 3 bytes touches at most 8 lanes, so it
  // can never spill past beat B — guard that the strobe is exhausted by two words.
  no_3word_wr: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (wst==W_IDLE && m_req && m_we) |-> ((({4'd0, m_wstrb} << m_addr[1:0]) >> 8) == 8'd0));
  // RLAST must land exactly on the last beat (catches a slave's early/late RLAST —
  // the beat counter now ignores RLAST for the FSM exit, this SVA flags the abuse).
  rlast_align: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_DATA && m_axi_rvalid && m_axi_rready && m_axi_rlast)
      |-> (r_beat == 8'(LINE_BEATS-1)));
  // every consumed response is OKAY (a SLVERR/DECERR would silently corrupt a line /
  // a store — sticky-flagged in rresp_err/bresp_err; an error pin to the core is a
  // documented follow-up, see fpga/L1_AXI_DESIGN.md).
  rresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_DATA && m_axi_rvalid && m_axi_rready) |-> (m_axi_rresp == 2'b00));
  bresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (wst==W_RESP && m_axi_bvalid) |-> (m_axi_bresp == 2'b00));
  no_resp_err: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (!rresp_err && !bresp_err));
  // every access fits the remap window — but ONLY when no aliasing is configured
  // (~ADDR_MASK==0). Under the KV260 4 GiB-top alias (ADDR_MASK=0x0FFF_FFFF) the high
  // bits ARE intentionally folded by remap() (SeaBIOS POSTs from 0xFFFFxxxx -> the
  // staged carveout copy), so the window check would be a FALSE positive; gate it off.
  araddr_window: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_IDLE && m_req && !m_we && (~ADDR_MASK == 32'd0))
      |-> ((m_addr & ~ADDR_MASK) == 32'd0));
  awaddr_window: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (wst==W_IDLE && m_req &&  m_we && (~ADDR_MASK == 32'd0))
      |-> ((m_addr & ~ADDR_MASK) == 32'd0));
`endif

  // lint sinks: RID/BID not consulted (single in-flight, AxID=0); axi_clk/axi_rst_n
  // are tied to the core domain in the CDC_BYPASS build. (RRESP/BRESP ARE consulted
  // now — the sticky rresp_err/bresp_err flags + the resp SVAs above.)
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, m_axi_bid, m_axi_rid, axi_clk, axi_rst_n};
  // verilator lint_on UNUSED

endmodule : ven_axi_master
