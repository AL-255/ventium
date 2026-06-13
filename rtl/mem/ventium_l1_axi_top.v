// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ventium_l1_axi_top.v — Verilog-2001 BD-reference wrapper for ventium_l1_axi.
//
// Vivado's block-design "Module Reference" flow rejects a SystemVerilog file as the
// TOP of the reference ([filemgmt 56-195]); the top must be plain Verilog. This thin
// wrapper is that top: it carries the Xilinx X_INTERFACE attributes (so the BD infers
// the AXI4 master bundle `m_axi` and the clock/reset associations) and instantiates
// the SystemVerilog ventium_l1_axi underneath (a sub-module IS allowed to be SV).
//
// REMAP_BASE / ADDR_MASK are pinned to the reserved DDR carveout (DDR_LOW @ 1 GiB,
// 256 MiB window) — this must equal the BD address segment offset/size and the
// PetaLinux reserved-memory node (the three-way identity). ADDR_W=40 matches the
// PS8 S_AXI_HPC0 master address width.

module ventium_l1_axi_top #(
    parameter ADDR_W = 40
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 core_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET core_rst_n" *)
    input  wire              core_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 core_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire              core_rst_n,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axi, ASSOCIATED_RESET axi_rst_n" *)
    input  wire              axi_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire              axi_rst_n,

    // ---- core side (driven by a test harness / the Ventium core mem_* port) ----
    input  wire              flush_all,   // #35 external L1 invalidation
    input  wire              core_req,
    input  wire              core_we,
    input  wire [31:0]       core_addr,
    input  wire [31:0]       core_wdata,
    input  wire [3:0]        core_wstrb,
    output wire [31:0]       core_rdata,
    output wire              core_ack,
    output wire              bus_err,    // #34 fatal AXI fault (PS observes -> reset)
    input  wire              shutdown,   // clean-shutdown quiesce -> ven_axi_master
    output wire              m_idle,     // AXI master drained (safe to remove overlay)

    // ---- AXI4 master bundle `m_axi` (-> S_AXI_HPC0_FPD) ------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWID" *)
    output wire [3:0]        m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    output wire [ADDR_W-1:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLEN" *)
    output wire [7:0]        m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWSIZE" *)
    output wire [2:0]        m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWBURST" *)
    output wire [1:0]        m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLOCK" *)
    output wire              m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWCACHE" *)
    output wire [3:0]        m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWPROT" *)
    output wire [2:0]        m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWQOS" *)
    output wire [3:0]        m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWVALID" *)
    output wire              m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWREADY" *)
    input  wire              m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WDATA" *)
    output wire [31:0]       m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WSTRB" *)
    output wire [3:0]        m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WLAST" *)
    output wire              m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WVALID" *)
    output wire              m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WREADY" *)
    input  wire              m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BID" *)
    input  wire [3:0]        m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BRESP" *)
    input  wire [1:0]        m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BVALID" *)
    input  wire              m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BREADY" *)
    output wire              m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARID" *)
    output wire [3:0]        m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARADDR" *)
    output wire [ADDR_W-1:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLEN" *)
    output wire [7:0]        m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARSIZE" *)
    output wire [2:0]        m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARBURST" *)
    output wire [1:0]        m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLOCK" *)
    output wire              m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARCACHE" *)
    output wire [3:0]        m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARPROT" *)
    output wire [2:0]        m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARQOS" *)
    output wire [3:0]        m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARVALID" *)
    output wire              m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARREADY" *)
    input  wire              m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RID" *)
    input  wire [3:0]        m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RDATA" *)
    input  wire [31:0]       m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RRESP" *)
    input  wire [1:0]        m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RLAST" *)
    input  wire              m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RVALID" *)
    input  wire              m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RREADY" *)
    output wire              m_axi_rready
);

  ventium_l1_axi #(
      .ADDR_W     (ADDR_W),
      .REMAP_BASE (40'h00_4000_0000),   // == BD carveout offset (1 GiB)
      .ADDR_MASK  (32'h0FFF_FFFF)       // == carveout size-1 (256 MiB)
  ) u_l1axi (
      .core_clk    (core_clk),   .core_rst_n  (core_rst_n),
      .axi_clk     (axi_clk),    .axi_rst_n   (axi_rst_n),
      .flush_all   (flush_all),
      .shutdown    (shutdown),   .m_idle      (m_idle),
      .core_req    (core_req),   .core_we     (core_we),    .core_addr  (core_addr),
      .core_wdata  (core_wdata), .core_wstrb  (core_wstrb), .core_rdata (core_rdata),
      .core_ack    (core_ack),
      .bus_err     (bus_err),
      .m_axi_awid    (m_axi_awid),    .m_axi_awaddr  (m_axi_awaddr),
      .m_axi_awlen   (m_axi_awlen),   .m_axi_awsize  (m_axi_awsize),
      .m_axi_awburst (m_axi_awburst), .m_axi_awlock  (m_axi_awlock),
      .m_axi_awcache (m_axi_awcache), .m_axi_awprot  (m_axi_awprot),
      .m_axi_awqos   (m_axi_awqos),   .m_axi_awvalid (m_axi_awvalid),
      .m_axi_awready (m_axi_awready), .m_axi_wdata   (m_axi_wdata),
      .m_axi_wstrb   (m_axi_wstrb),   .m_axi_wlast   (m_axi_wlast),
      .m_axi_wvalid  (m_axi_wvalid),  .m_axi_wready  (m_axi_wready),
      .m_axi_bid     (m_axi_bid),     .m_axi_bresp   (m_axi_bresp),
      .m_axi_bvalid  (m_axi_bvalid),  .m_axi_bready  (m_axi_bready),
      .m_axi_arid    (m_axi_arid),    .m_axi_araddr  (m_axi_araddr),
      .m_axi_arlen   (m_axi_arlen),   .m_axi_arsize  (m_axi_arsize),
      .m_axi_arburst (m_axi_arburst), .m_axi_arlock  (m_axi_arlock),
      .m_axi_arcache (m_axi_arcache), .m_axi_arprot  (m_axi_arprot),
      .m_axi_arqos   (m_axi_arqos),   .m_axi_arvalid (m_axi_arvalid),
      .m_axi_arready (m_axi_arready), .m_axi_rid     (m_axi_rid),
      .m_axi_rdata   (m_axi_rdata),   .m_axi_rresp   (m_axi_rresp),
      .m_axi_rlast   (m_axi_rlast),   .m_axi_rvalid  (m_axi_rvalid),
      .m_axi_rready  (m_axi_rready)
  );

endmodule
