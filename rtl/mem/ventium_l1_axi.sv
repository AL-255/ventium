// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ventium_l1_axi.sv — the L1 + AXI4 memory subsystem (P1-1 step 2/3).
//
// The linchpin for booting Ventium on the KV260: it bridges the core's
// SAME-CYCLE-ACK 32-bit memory port (the dual-issue fast path latches load data
// the clock it asserts the request) to the PS DDR4 over AXI4 (multi-cycle), hiding
// DDR latency behind the L1 cache that acks on a hit in the same clock.
//
//   core mem_*  ──►  ven_l1d  ──(word backing port)──►  ven_axi_master  ──►  AXI4
//   (same-cycle      (8KB/2-way      (coalesce the 8-word         (-> S_AXI_HPC0_FPD
//    ack on hit)      32B line)       line fill into 1 INCR        -> SmartConnect
//                                     burst; write = 1 beat)       -> PS DDR)
//
// Contract presented to the core (fpga/L1_AXI_DESIGN.md §1):
//   * READ HIT  -> c_rdata valid + c_ack=1 the SAME clock (combinational off the L1
//     arrays). Mandatory: the fast path has no register stage on the load.
//   * READ MISS -> c_ack=0 (the core stalls / the fast-path miss-stall gate holds)
//     while the AXI burst fills the line; the retry then hits.
//   * WRITE     -> write-through; c_ack pulses when the AXI write is accepted (B).
//
// REMAP_BASE/ADDR_MASK place the x86 physical space into the reserved DDR window
// (ddr_addr = REMAP_BASE + (phys & ADDR_MASK)); the L1 itself is purely
// PHYSICAL-addressed (no TLB inside — the core already translated).
//
// The m_axi_* ports carry Xilinx X_INTERFACE attributes so Vivado's Module-
// Reference flow infers a single AXI4 master bundle named `m_axi` (else the BD's
// connect_bd_intf_net to S_AXI_HPC0 finds no interface pin). core_clk and axi_clk
// are separate ports; the BD ties both to pl_clk0 (single-clock bring-up, the
// CDC_BYPASS build), leaving room for a later MMCM dual-clock variant.

module ventium_l1_axi #(
    parameter int          L1_SETS    = 128,
    parameter int          L1_LINE    = 32,                // bytes/line
    parameter int          ADDR_W     = 40,                // PS8 HPC0 master addr
    parameter logic [39:0] REMAP_BASE = 40'h00_0000_0000,
    parameter logic [31:0] ADDR_MASK  = 32'hFFFF_FFFF,
    parameter logic [3:0]  AXI_ID     = 4'd0,
    parameter int unsigned WATCHDOG   = 1024            // #34 AXI stall watchdog cycles
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 core_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET core_rst_n" *)
    input  logic        core_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 core_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic        core_rst_n,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axi, ASSOCIATED_RESET axi_rst_n" *)
    input  logic        axi_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic        axi_rst_n,

    // ---- core side (the same-cycle-ack contract; mirrors core mem_*) ----------
    input  logic        flush_all,       // #35 external L1 invalidation (clear all val)
    input  logic        core_req,
    input  logic        core_we,
    input  logic [31:0] core_addr,
    input  logic [31:0] core_wdata,
    input  logic [3:0]  core_wstrb,
    output logic [31:0] core_rdata,
    output logic        core_ack,
    output logic        bus_err,        // #34 fatal AXI fault (watchdog timeout / SLVERR)

    // ---- AXI4 master port (-> S_AXI_HPC0_FPD), bundle `m_axi` ------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWID" *)
    output logic [3:0]        m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    output logic [ADDR_W-1:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLEN" *)
    output logic [7:0]        m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWSIZE" *)
    output logic [2:0]        m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWBURST" *)
    output logic [1:0]        m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLOCK" *)
    output logic              m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWCACHE" *)
    output logic [3:0]        m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWPROT" *)
    output logic [2:0]        m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWQOS" *)
    output logic [3:0]        m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWVALID" *)
    output logic              m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWREADY" *)
    input  logic              m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WDATA" *)
    output logic [31:0]       m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WSTRB" *)
    output logic [3:0]        m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WLAST" *)
    output logic              m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WVALID" *)
    output logic              m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WREADY" *)
    input  logic              m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BID" *)
    input  logic [3:0]        m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BRESP" *)
    input  logic [1:0]        m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BVALID" *)
    input  logic              m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BREADY" *)
    output logic              m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARID" *)
    output logic [3:0]        m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARADDR" *)
    output logic [ADDR_W-1:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLEN" *)
    output logic [7:0]        m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARSIZE" *)
    output logic [2:0]        m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARBURST" *)
    output logic [1:0]        m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLOCK" *)
    output logic              m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARCACHE" *)
    output logic [3:0]        m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARPROT" *)
    output logic [2:0]        m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARQOS" *)
    output logic [3:0]        m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARVALID" *)
    output logic              m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARREADY" *)
    input  logic              m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RID" *)
    input  logic [3:0]        m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RDATA" *)
    input  logic [31:0]       m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RRESP" *)
    input  logic [1:0]        m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RLAST" *)
    input  logic              m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RVALID" *)
    input  logic              m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RREADY" *)
    output logic              m_axi_rready
);

  // ---- internal word-granular backing port (L1 <-> AXI master) --------------
  // ven_l1d's backing master (always in core_clk). In the default single-clock
  // build these wire STRAIGHT to ven_axi_master; in +VEN_AXI_CDC they cross to the
  // axi_clk domain through ven_axi_cdc first (see below).
  logic        m_req, m_we;
  logic [31:0] m_addr, m_wdata;
  logic [3:0]  m_wstrb;
  logic [31:0] m_rdata;
  logic        m_ack;

  // ven_axi_master's backing slave + its clock/reset — a COMPILE-TIME (ifdef) alias
  // of either the core domain (default) or the axi domain (+VEN_AXI_CDC). Static
  // selection: exactly one `assign` exists per build, so axm_clk is a direct net
  // alias (no runtime clock mux / gated clock), and ven_axi_master stays UNTOUCHED
  // (it is single-clock on whichever clock it is handed).
  logic        axm_clk, axm_rst_n;
  logic        axm_req, axm_we;
  logic [31:0] axm_addr, axm_wdata;
  logic [3:0]  axm_wstrb;
  logic [31:0] axm_rdata;
  logic        axm_ack, axm_bus_err;

  // l1d uses a domain-synchronized reset in the CDC build, the raw reset otherwise.
  logic        l1d_rst_n;

`ifdef VEN_AXI_CDC
  // ---- dual-clock: synchronize each domain's reset, then bridge the backing port.
  // #36 RESET COUPLING (review HIGH): a reset in EITHER domain must reset BOTH. An
  // asymmetric reset mid-transaction (e.g. an AXI soft-reset / MMCM lock loss drops
  // ONLY axi_rst_n) would wipe the producer state of an in-flight transaction: the
  // command was already popped, so no response is ever pushed, ven_l1d hangs in its
  // fill forever, AND the #34 watchdog (living in the just-reset axi domain) cannot
  // fire -> an undetectable deadlock. AND the raw resets so the UNION of reset events
  // async-asserts both per-domain synchronizers together (glitch-safe for a level
  // async-assert; each domain still sync-DEASSERTS cleanly in its own clock, and on
  // deassertion the FIFOs/FSMs are idle so the sync-latency skew is benign).
  logic rst_comb_n;
  assign rst_comb_n = core_rst_n & axi_rst_n;
  logic core_rst_sync_n, axi_rst_sync_n;
  ven_reset_sync u_rs_core (.clk(core_clk), .arst_n(rst_comb_n), .srst_n(core_rst_sync_n));
  ven_reset_sync u_rs_axi  (.clk(axi_clk),  .arst_n(rst_comb_n), .srst_n(axi_rst_sync_n));
  assign l1d_rst_n = core_rst_sync_n;
  assign axm_clk   = axi_clk;
  assign axm_rst_n = axi_rst_sync_n;

  ven_axi_cdc #(.LINE_BEATS(L1_LINE/4)) u_cdc (
      .core_clk   (core_clk),        .core_rst_n (core_rst_sync_n),
      .axi_clk    (axi_clk),         .axi_rst_n  (axi_rst_sync_n),
      // core side: ven_l1d's backing master
      .c_req      (m_req),  .c_we    (m_we),    .c_addr  (m_addr),
      .c_wdata    (m_wdata),.c_wstrb (m_wstrb), .c_rdata (m_rdata),
      .c_ack      (m_ack),  .bus_err (bus_err),
      // axi side: drives ven_axi_master's backing slave
      .a_req      (axm_req),  .a_we    (axm_we),    .a_addr  (axm_addr),
      .a_wdata    (axm_wdata),.a_wstrb (axm_wstrb), .a_rdata (axm_rdata),
      .a_ack      (axm_ack),  .a_bus_err(axm_bus_err)
  );
`else
  // ---- default single-clock (CDC_BYPASS): wire the backing port straight through.
  assign l1d_rst_n = core_rst_n;
  assign axm_clk   = core_clk;
  assign axm_rst_n = core_rst_n;
  assign axm_req   = m_req;   assign axm_we    = m_we;
  assign axm_addr  = m_addr;  assign axm_wdata = m_wdata;  assign axm_wstrb = m_wstrb;
  assign m_rdata   = axm_rdata; assign m_ack   = axm_ack;  assign bus_err   = axm_bus_err;
`endif

  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (
      .clk      (core_clk),
      .rst_n    (l1d_rst_n),
      .flush_all(flush_all),
      .c_req   (core_req),
      .c_we    (core_we),
      .c_addr  (core_addr),
      .c_wdata (core_wdata),
      .c_wstrb (core_wstrb),
      .c_rdata (core_rdata),
      .c_ack   (core_ack),
      .m_req   (m_req),
      .m_we    (m_we),
      .m_addr  (m_addr),
      .m_wdata (m_wdata),
      .m_wstrb (m_wstrb),
      .m_rdata (m_rdata),
      .m_ack   (m_ack)
  );

  ven_axi_master #(
      .LINE_BEATS (L1_LINE/4),
      .ADDR_W     (ADDR_W),
      .REMAP_BASE (REMAP_BASE),
      .ADDR_MASK  (ADDR_MASK),
      .AXI_ID     (AXI_ID),
      .WATCHDOG   (WATCHDOG)
  ) u_axi (
      .core_clk    (axm_clk),
      .core_rst_n  (axm_rst_n),
      .axi_clk     (axi_clk),
      .axi_rst_n   (axi_rst_n),
      .m_req       (axm_req),
      .m_we        (axm_we),
      .m_addr      (axm_addr),
      .m_wdata     (axm_wdata),
      .m_wstrb     (axm_wstrb),
      .m_rdata     (axm_rdata),
      .m_ack       (axm_ack),
      .bus_err     (axm_bus_err),
      .m_axi_awid    (m_axi_awid),
      .m_axi_awaddr  (m_axi_awaddr),
      .m_axi_awlen   (m_axi_awlen),
      .m_axi_awsize  (m_axi_awsize),
      .m_axi_awburst (m_axi_awburst),
      .m_axi_awlock  (m_axi_awlock),
      .m_axi_awcache (m_axi_awcache),
      .m_axi_awprot  (m_axi_awprot),
      .m_axi_awqos   (m_axi_awqos),
      .m_axi_awvalid (m_axi_awvalid),
      .m_axi_awready (m_axi_awready),
      .m_axi_wdata   (m_axi_wdata),
      .m_axi_wstrb   (m_axi_wstrb),
      .m_axi_wlast   (m_axi_wlast),
      .m_axi_wvalid  (m_axi_wvalid),
      .m_axi_wready  (m_axi_wready),
      .m_axi_bid     (m_axi_bid),
      .m_axi_bresp   (m_axi_bresp),
      .m_axi_bvalid  (m_axi_bvalid),
      .m_axi_bready  (m_axi_bready),
      .m_axi_arid    (m_axi_arid),
      .m_axi_araddr  (m_axi_araddr),
      .m_axi_arlen   (m_axi_arlen),
      .m_axi_arsize  (m_axi_arsize),
      .m_axi_arburst (m_axi_arburst),
      .m_axi_arlock  (m_axi_arlock),
      .m_axi_arcache (m_axi_arcache),
      .m_axi_arprot  (m_axi_arprot),
      .m_axi_arqos   (m_axi_arqos),
      .m_axi_arvalid (m_axi_arvalid),
      .m_axi_arready (m_axi_arready),
      .m_axi_rid     (m_axi_rid),
      .m_axi_rdata   (m_axi_rdata),
      .m_axi_rresp   (m_axi_rresp),
      .m_axi_rlast   (m_axi_rlast),
      .m_axi_rvalid  (m_axi_rvalid),
      .m_axi_rready  (m_axi_rready)
  );

endmodule : ventium_l1_axi
