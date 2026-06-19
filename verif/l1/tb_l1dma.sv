// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1dma.sv — Phase D coherence gate (docs/northbridge-system-spec.md §1,5).
// Drives BOTH the CPU side (c_*) and the coherent DMA requester (dma_*) of ventium_l1_axi
// built EN_L2=1 (+VEN_NB_DMA), and proves the northbridge keeps the CPU L1 coherent with a
// DMA bus master:
//   * DMA WRITE → snoop-invalidate: the CPU caches a line, a DMA write updates it (in the
//     write-back L2, NOT yet in DDR), the northbridge snoop drops the stale L1 copy, so the
//     CPU's next read refills the NEW value;
//   * DMA READ sees CPU-dirtied data: the CPU writes a line (write-through into the L2,
//     dirty, not yet in DDR), a DMA read through the L2 returns the CPU's value (not stale DDR);
//   * uncacheable DMA write bypasses the L2 straight to DDR;
//   * the CPU/DMA arbiter interleaves correctly.
// Built with +define+VEN_NB_DMA +define+VEN_DBG_CORE +define+VEN_DBG_L2.
// Prints L1DMA-GATE-OK / -FAIL. Run via verif/l1/run-l1dma-gate.sh.

module tb_l1dma;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;
  localparam int          L2_CAP     = 512;
  localparam int          L2_WAYS    = 2;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        dma_req, dma_we; logic [31:0] dma_addr, dma_wdata; logic [3:0] dma_wstrb;
  logic [31:0] dma_rdata; logic dma_ack;

  logic [3:0]  awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]  awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]  awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]  bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]  arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]  arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]  arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]  rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  logic bus_err; logic flush = 1'b0; logic shutdown = 1'b0; logic m_idle;
  logic        dbg_rd_valid; logic [31:0] dbg_rd_addr, dbg_rd_data;
  logic        dbg_l2_ready; logic [31:0] dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK),
                   .EN_L2(1'b1), .L2_CAP_BYTES(L2_CAP), .L2_WAYS(L2_WAYS)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(shutdown), .m_idle(m_idle),
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

  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(4), .WR_LAT(3), .BUBBLE(1)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0; forever begin @(posedge clk); #1; if (c_ack) begin d=c_rdata; break; end
      if (++guard>400) begin $display("  FAIL cpu read %08x: no ack",a); errors++; d=32'hx; break; end end
    @(negedge clk); c_req<=1'b0;
  endtask
  task automatic do_write(input logic [31:0] a, d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    guard=0; forever begin @(posedge clk); #1; if (c_ack) break;
      if (++guard>400) begin $display("  FAIL cpu write %08x: no ack",a); errors++; break; end end
    @(negedge clk); c_req<=1'b0; c_we<=1'b0;
  endtask
  // DMA WRITE: one backing transaction (we=1, byte addr + strobes), wait dma_ack.
  task automatic do_dma_write(input logic [31:0] a, d);
    int guard;
    @(negedge clk); dma_req<=1'b1; dma_we<=1'b1; dma_addr<=a; dma_wdata<=d; dma_wstrb<=4'hF;
    guard=0; forever begin @(posedge clk); #1; if (dma_ack) break;
      if (++guard>400) begin $display("  FAIL dma write %08x: no ack",a); errors++; break; end end
    @(negedge clk); dma_req<=1'b0; dma_we<=1'b0;
  endtask
  // DMA READ: a line read (WORDS acks), return the addressed word.
  task automatic do_dma_read(input logic [31:0] a, output logic [31:0] d);
    int i, guard; logic [31:0] words[8];
    @(negedge clk); dma_req<=1'b1; dma_we<=1'b0; dma_addr<={a[31:5],5'd0}; dma_wstrb<=4'd0;
    i=0; guard=0;
    forever begin @(posedge clk); #1;
      if (dma_ack) begin words[i]=dma_rdata; i++; if (i==8) break; end
      if (++guard>400) begin $display("  FAIL dma read %08x: no ack (got %0d)",a,i); errors++; break; end
    end
    @(negedge clk); dma_req<=1'b0;
    d = words[a[4:2]];
  endtask

  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    dma_req=0; dma_we=0; dma_addr=0; dma_wdata=0; dma_wstrb=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [32:0] a=0; a<33'h10_0000; a+=4) slv.poke(a[31:0], a[31:0] ^ 32'hA5A5_0000);
    repeat(4) @(posedge clk); rst_n<=1'b1;
    begin int g; g=0; forever begin @(posedge clk); #1; if (dbg_l2_ready) break;
      if (++g>1000) begin $display("  FAIL L2 never ready"); errors++; break; end end end

    $display("[1] DMA WRITE -> snoop invalidates the CPU L1 -> CPU reads the NEW value");
    do_read(32'h0000_1000, d); chk("CPU cached line@1000", d, 32'h1000 ^ 32'hA5A5_0000);
    do_dma_write(32'h0000_1000, 32'hD00D_0001);                 // DMA writes it (into the L2)
    chk("DDR still OLD (write-back, not DDR)", slv.peek(32'h0000_1000), 32'h1000 ^ 32'hA5A5_0000);
    do_read(32'h0000_1000, d); chk("CPU re-read is COHERENT (snoop worked)", d, 32'hD00D_0001);

    $display("[2] DMA READ sees CPU-dirtied data through the L2 (not stale DDR)");
    do_write(32'h0000_2000, 32'hC0DE_0002);                     // CPU write-through -> L2 dirty
    chk("DDR still OLD for 0x2000 (write-back)", slv.peek(32'h0000_2000), 32'h2000 ^ 32'hA5A5_0000);
    do_dma_read(32'h0000_2000, d); chk("DMA read sees CPU value", d, 32'hC0DE_0002);

    $display("[3] UNCACHEABLE DMA write (0xA0000) bypasses the L2 straight to DDR");
    do_dma_write(32'h000A_0000, 32'hBEEF_0003);
    repeat(6) @(posedge clk);
    chk("DDR got the uncacheable DMA write", slv.peek(32'h000A_0000), 32'hBEEF_0003);

    $display("[4] arbiter interleave: CPU + DMA on the same line, both coherent");
    do_read(32'h0000_3000, d); chk("CPU cached line@3000", d, 32'h3000 ^ 32'hA5A5_0000);
    do_dma_write(32'h0000_3000, 32'h0A11_0004);
    do_read(32'h0000_3000, d); chk("CPU sees DMA write@3000", d, 32'h0A11_0004);
    do_dma_read(32'h0000_3000, d); chk("DMA reads back its own write", d, 32'h0A11_0004);

    $display("[5] counters: hits=%0d misses=%0d wbacks=%0d bypass=%0d",
             dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass);

    if (errors==0) $display("L1DMA-GATE-OK (all checks pass)");
    else           $display("L1DMA-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #500000; $display("L1DMA-GATE-FAIL (timeout)"); $finish; end
endmodule
