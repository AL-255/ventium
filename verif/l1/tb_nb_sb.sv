// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_nb_sb.sv — Phase E.system gate: the NORTHBRIDGE ↔ SOUTHBRIDGE link as a
// unit. Composes ventium_l1_axi (EN_L2=1, +VEN_NB_DMA +VEN_NB_MMIO — the live L2/NB) with
// ven_southbridge, a DDR slave, and a synthetic CPU on the core port. Proves:
//   * CPU memory access to the device aperture (0xA0000) routes NB.mmio_* → southbridge
//     framebuffer (write/read-back) — device MMIO never touches L2/DDR;
//   * the southbridge's 8237 bus-masters memory through NB.dma_* → L2, COHERENTLY: a DMA
//     write to a CPU-cached line snoop-invalidates the L1 so the CPU's next read sees it.
// Built with +VEN_NB_DMA +VEN_NB_MMIO +VEN_DBG_CORE +VEN_DBG_L2. Prints NBSB-GATE-OK/-FAIL.

module tb_nb_sb;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;
  localparam int          L2_CAP     = 512;
  localparam int          L2_WAYS    = 2;

  logic clk=0, rst_n=0; always #5 clk=~clk;

  // CPU (core) side of the northbridge
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  // AXI to DDR
  logic [3:0]  awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]  awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]  awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]  bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]  arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]  arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]  arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]  rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;
  logic bus_err, m_idle;
  logic dbg_rd_valid; logic [31:0] dbg_rd_addr, dbg_rd_data;
  logic dbg_l2_ready; logic [31:0] dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass;

  // NB ↔ SB: MMIO master (NB out) + DMA requester (SB → NB)
  logic        mmio_req, mmio_we; logic [31:0] mmio_addr, mmio_wdata; logic [3:0] mmio_wstrb;
  logic [31:0] mmio_rdata; logic mmio_ack;
  logic        dma_req, dma_we; logic [31:0] dma_addr, dma_wdata; logic [3:0] dma_wstrb;
  logic [31:0] dma_rdata; logic dma_ack;
  // SB device-side: port-I/O (CPU programs the 8237/PCI cfg) + DMA device data + IDE master
  logic        io_req, io_we; logic [15:0] io_addr; logic [31:0] io_wdata, io_rdata; logic io_ack;
  logic        dev_rd, dev_wr; logic [31:0] dev_rdata, dev_wdata; logic dma_busy, dma_tc;
  logic        ide_req=0, ide_we=0; logic [31:0] ide_addr=0, ide_wdata=0; logic [3:0] ide_wstrb=0;
  logic [31:0] ide_rdata; logic ide_ack;
  logic [55:0] cfg_pam; logic [7:0] cfg_dramc, cfg_cc, cfg_tom_mb4, cfg_smram;

  // ---- the LIVE northbridge (ventium_l1_axi EN_L2=1) -------------------------
  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK),
                   .EN_L2(1'b1), .L2_CAP_BYTES(L2_CAP), .L2_WAYS(L2_WAYS)) u_nb (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .mmio_req(mmio_req), .mmio_we(mmio_we), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
      .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata), .mmio_ack(mmio_ack),
      .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
      .dma_wstrb(dma_wstrb), .dma_rdata(dma_rdata), .dma_ack(dma_ack),
      .dbg_rd_valid(dbg_rd_valid), .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
      .dbg_l2_ready(dbg_l2_ready), .dbg_l2_hits(dbg_l2_hits), .dbg_l2_misses(dbg_l2_misses),
      .dbg_l2_wbacks(dbg_l2_wbacks), .dbg_l2_bypass(dbg_l2_bypass),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack), .bus_err(bus_err),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
      .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // ---- the southbridge: MMIO slave ← NB, DMA master → NB ---------------------
  ven_southbridge u_sb (
      .clk(clk), .rst_n(rst_n),
      .mmio_req(mmio_req), .mmio_we(mmio_we), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
      .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata), .mmio_ack(mmio_ack),
      .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
      .io_rdata(io_rdata), .io_ack(io_ack),
      .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
      .dma_wstrb(dma_wstrb), .dma_rdata(dma_rdata), .dma_ack(dma_ack),
      .dev_rd(dev_rd), .dev_rdata(dev_rdata), .dev_wr(dev_wr), .dev_wdata(dev_wdata),
      .dma_busy(dma_busy), .dma_tc(dma_tc),
      .ide_req(ide_req), .ide_we(ide_we), .ide_addr(ide_addr), .ide_wdata(ide_wdata),
      .ide_wstrb(ide_wstrb), .ide_rdata(ide_rdata), .ide_ack(ide_ack),
      .cfg_pam(cfg_pam), .cfg_dramc(cfg_dramc), .cfg_cc(cfg_cc),
      .cfg_tom_mb4(cfg_tom_mb4), .cfg_smram(cfg_smram));

  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(3), .WR_LAT(2), .BUBBLE(1)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  // DMA device source (a disk supplying a pattern)
  int devidx; logic [31:0] devpat [0:63];
  assign dev_rdata = devpat[devidx[5:0]];
  always_ff @(posedge clk) if (dev_rd) devidx <= devidx + 1;

  int errors=0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic do_read(input [31:0] a, output [31:0] d);
    int g; @(negedge clk); c_req<=1; c_we<=0; c_addr<=a; c_wstrb<=0;
    g=0; forever begin @(posedge clk); #1; if (c_ack) begin d=c_rdata; break; end
      if (++g>400) begin $display("  FAIL cpu read %08x no ack",a); errors++; d=32'hx; break; end end
    @(negedge clk); c_req<=0;
  endtask
  task automatic do_write(input [31:0] a, d);
    int g; @(negedge clk); c_req<=1; c_we<=1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    g=0; forever begin @(posedge clk); #1; if (c_ack) break;
      if (++g>400) begin $display("  FAIL cpu write %08x no ack",a); errors++; break; end end
    @(negedge clk); c_req<=0; c_we<=0;
  endtask
  task automatic io_w(input [15:0] a, input [31:0] d);
    @(negedge clk); io_req<=1; io_we<=1; io_addr<=a; io_wdata<=d; @(negedge clk); io_req<=0; io_we<=0;
  endtask

  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0; io_req=0; io_we=0; io_addr=0; io_wdata=0; devidx=0;
    for (int i=0;i<64;i++) devpat[i]=32'hD15C_0000+i;
    for (int i=0;i<(1<<20);i++) slv.mem[i]=8'h00;
    for (logic [32:0] a=0; a<33'h10_0000; a+=4) slv.poke(a[31:0], a[31:0] ^ 32'hA5A5_0000);
    repeat(4) @(posedge clk); rst_n<=1'b1;
    begin int g; g=0; forever begin @(posedge clk); #1; if (dbg_l2_ready) break;
      if (++g>1000) begin $display("  FAIL L2 never ready"); errors++; break; end end end

    $display("[1] CPU mem access to device aperture (0xA0000) → NB.mmio_* → southbridge FB");
    do_write(32'h000A_0000, 32'hCAFE_F00D);
    do_read (32'h000A_0000, d); chk("CPU reads back from the SB framebuffer", d, 32'hCAFE_F00D);
    do_read (32'h0000_1000, d); chk("cacheable DRAM still works (via L2)", d, 32'h1000 ^ 32'hA5A5_0000);

    $display("[2] southbridge 8237 bus-masters memory through NB.dma_* → L2, COHERENT");
    do_read(32'h0000_2000, d); chk("CPU caches line@2000", d, 32'h2000 ^ 32'hA5A5_0000);
    devidx = 0;
    io_w(16'h000C, 32'h00);                               // 8237: clear FF
    io_w(16'h0000, 32'h00); io_w(16'h0000, 32'h20);       // ch0 addr 0x2000
    io_w(16'h0001, 32'h03); io_w(16'h0001, 32'h00);       // ch0 count 3 (4 words)
    io_w(16'h0087, 32'h00); io_w(16'h000B, 32'h44); io_w(16'h000A, 32'h00); // page/mode-write/unmask
    io_w(16'h0009, 32'h04);                               // request ch0 → GO
    begin int g; g=0; forever begin @(posedge clk); #1; if (dma_tc) break;
      if (++g>2000) begin $display("  FAIL SB DMA never completed"); errors++; break; end end end
    do_read(32'h0000_2000, d); chk("CPU re-read is COHERENT (SB-DMA snoop worked)", d, 32'hD15C_0000);
    do_read(32'h0000_2004, d); chk("word 1 too", d, 32'hD15C_0001);

    $display("[3] counters: hits=%0d misses=%0d wbacks=%0d bypass=%0d",
             dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass);
    if (errors==0) $display("NBSB-GATE-OK (all checks pass)");
    else           $display("NBSB-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #1000000; $display("NBSB-GATE-FAIL (timeout)"); $finish; end
endmodule
