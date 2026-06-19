// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1nb.sv — Phase C gate for the northbridge cacheability routing
// (docs/northbridge-system-spec.md §4-5). Drives the CORE side of ventium_l1_axi built
// with EN_L2=1 (ven_l1d → ven_northbridge{ven_cachemap + ven_l2 + bypass} → AXI DDR) and
// proves the cachemap actually STEERS traffic:
//   * CACHEABLE DRAM → through the L2: re-read after an L1 flush HITS the L2 (no new AR);
//   * UNCACHEABLE video aperture (0xA0000-0xBFFFF, always non-cacheable per the TSC) →
//     BYPASSES the L2 *and* is not L1-cached: a DMA-style backing change is seen on the
//     very next read (proving nothing cached it), the L2 hit/miss counters do NOT move
//     for it, and the bypass counter does;
//   * the uncacheable traffic does not pollute/evict the cacheable line (it still hits L2).
// Built with +define+VEN_DBG_CORE +define+VEN_DBG_L2. Prints L1NB-GATE-OK / -FAIL.
// Run via verif/l1/run-l1nb-gate.sh.

module tb_l1nb;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;
  localparam int          L2_CAP     = 512;     // tiny L2 (2-way, 8 sets) → fast init
  localparam int          L2_WAYS    = 2;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;

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

  int ar_count = 0, aw_count = 0;
  always @(posedge clk) begin
    if (arvalid && arready) ar_count++;
    if (awvalid && awready) aw_count++;
  end

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK),
                   .EN_L2(1'b1), .L2_CAP_BYTES(L2_CAP), .L2_WAYS(L2_WAYS)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(shutdown), .m_idle(m_idle),
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
  task automatic chk_int(input string what, input int got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0;
    forever begin @(posedge clk); #1; if (c_ack) begin d=c_rdata; break; end
      if (++guard>300) begin $display("  FAIL read %08x: no ack", a); errors++; d=32'hx; break; end end
    @(negedge clk); c_req<=1'b0;
  endtask
  task automatic do_write(input logic [31:0] a, d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    guard=0;
    forever begin @(posedge clk); #1; if (c_ack) break;
      if (++guard>300) begin $display("  FAIL write %08x: no ack",a); errors++; break; end end
    @(negedge clk); c_req<=1'b0; c_we<=1'b0;
  endtask
  task automatic do_flush();
    @(negedge clk); flush <= 1'b1; @(posedge clk); @(negedge clk); flush <= 1'b0;
  endtask

  logic [31:0] d; int ar0, h0, m0, byp0;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [32:0] a=0; a<33'h10_0000; a+=4) slv.poke(a[31:0], a[31:0] ^ 32'hA5A5_0000); // seed 0-1MB
    repeat(4) @(posedge clk); rst_n<=1'b1;
    begin int g; g=0;
      forever begin @(posedge clk); #1; if (dbg_l2_ready) break;
        if (++g>1000) begin $display("  FAIL L2 never ready"); errors++; break; end end
    end

    $display("[1] CACHEABLE DRAM (0x1000) routes THROUGH the L2 (hit after L1 flush, no new AR)");
    do_read(32'h0000_1000, d); chk("cacheable read", d, 32'h1000 ^ 32'hA5A5_0000);
    do_flush();
    ar0 = ar_count;
    do_read(32'h0000_1000, d); chk("re-read (L1 miss)", d, 32'h1000 ^ 32'hA5A5_0000);
    chk_int("L2 hit -> no new AXI AR", ar_count - ar0, 0);
    if (dbg_l2_hits == 0) begin $display("  FAIL dbg_l2_hits==0"); errors++; end
    else $display("  ok   dbg_l2_hits = %0d", dbg_l2_hits);

    $display("[2] UNCACHEABLE video aperture (0xA0000) BYPASSES the L2 and is NOT cached");
    h0 = dbg_l2_hits; m0 = dbg_l2_misses; byp0 = dbg_l2_bypass;
    do_read(32'h000A_0000, d); chk("video read (from DDR via bypass)", d, 32'hA0000 ^ 32'hA5A5_0000);
    chk_int("bypass counter advanced", dbg_l2_bypass - byp0 > 0 ? 1 : 0, 1);
    chk_int("L2 hits NOT touched by uncacheable", dbg_l2_hits - h0, 0);
    chk_int("L2 misses NOT touched by uncacheable", dbg_l2_misses - m0, 0);
    // a backing change must be visible on the NEXT read → nothing cached it (L1 or L2).
    slv.poke(32'h000A_0000, 32'hF00D_CAFE);
    do_read(32'h000A_0000, d); chk("re-read sees DMA change (uncached)", d, 32'hF00D_CAFE);

    $display("[2b] UNCACHEABLE write (0xA0008) is straight write-through to DDR");
    do_write(32'h000A_0008, 32'h1357_9BDF);
    repeat(6) @(posedge clk);
    chk("DDR got the uncacheable write", slv.peek(32'h000A_0008), 32'h1357_9BDF);

    $display("[3] the uncacheable traffic did NOT evict/pollute the cacheable line");
    do_flush();                                  // L1 only; the L2 must still hold 0x1000
    ar0 = ar_count;
    do_read(32'h0000_1000, d); chk("cacheable line still L2-resident", d, 32'h1000 ^ 32'hA5A5_0000);
    chk_int("still an L2 hit (no AR)", ar_count - ar0, 0);

    $display("[4] counters summary: hits=%0d misses=%0d wbacks=%0d bypass=%0d",
             dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass);

    if (errors==0) $display("L1NB-GATE-OK (all checks pass)");
    else           $display("L1NB-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #500000; $display("L1NB-GATE-FAIL (timeout)"); $finish; end
endmodule
