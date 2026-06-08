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
    parameter logic [3:0]  AXI_ID     = 4'd0
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
    input  logic        core_req,
    input  logic        core_we,
    input  logic [31:0] core_addr,
    input  logic [31:0] core_wdata,
    input  logic [3:0]  core_wstrb,
    output logic [31:0] core_rdata,
    output logic        core_ack,

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
  logic        m_req, m_we;
  logic [31:0] m_addr, m_wdata;
  logic [3:0]  m_wstrb;
  logic [31:0] m_rdata;
  logic        m_ack;

  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (
      .clk     (core_clk),
      .rst_n   (core_rst_n),
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
      .AXI_ID     (AXI_ID)
  ) u_axi (
      .core_clk    (core_clk),
      .core_rst_n  (core_rst_n),
      .axi_clk     (axi_clk),
      .axi_rst_n   (axi_rst_n),
      .m_req       (m_req),
      .m_we        (m_we),
      .m_addr      (m_addr),
      .m_wdata     (m_wdata),
      .m_wstrb     (m_wstrb),
      .m_rdata     (m_rdata),
      .m_ack       (m_ack),
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
