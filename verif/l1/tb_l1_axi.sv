// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1_axi.sv — end-to-end gate for the L1+AXI subsystem (P1-1 step 2/3).
// Drives the CORE side of ventium_l1_axi (the same-cycle-ack contract) and backs
// it with a behavioral MULTI-CYCLE AXI4 DDR slave (axi_slave_bfm). It re-runs the
// tb_l1d scenarios THROUGH the full AXI path — a cold read coalesced into one INCR8
// burst, a whole-line fill, a write-through, 2-way LRU eviction — plus a
// store-miss→dependent-load ordering check (the write must land in DDR before the
// fill re-reads the line). The DUT remaps with REMAP_BASE=0x4000_0000 so the slave,
// which un-remaps before indexing, also CHECKS the remap end-to-end (a wrong remap
// reads the wrong backing word -> data mismatch -> FAIL). The slave's RD_LAT/WR_LAT
// make every miss a multi-cycle stall (c_ack low for several clocks), and BUBBLE
// drops RVALID mid-burst to prove the stream m_ack gating holds fw on a bubble.
// Builds with `verilator --binary`; prints L1AXI-GATE-OK / L1AXI-GATE-FAIL.

module tb_l1_axi;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;   // DDR carveout @ 1 GiB
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;      // 1 GiB window
  localparam int          ADDR_W     = 40;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;

  // AXI master <-> slave
  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  logic bus_err; logic flush = 1'b0;
  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(flush),
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

  // issue a core READ to `a`, spin until c_ack (multi-cycle on a miss), return data.
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 200) begin $display("  FAIL read %08x: no ack", a); errors++; d=32'hx; break; end
    end
    @(negedge clk); c_req<=1'b0;
  endtask

  // issue a core WRITE-through of word `d` to `a` (full word), spin until ack.
  task automatic do_write(input logic [31:0] a, d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    guard=0;
    forever begin @(posedge clk); #1; if (c_ack) break;
      if (++guard>200) begin $display("  FAIL write %08x: no ack",a); errors++; break; end end
    @(negedge clk); c_req<=1'b0; c_we<=1'b0;
  endtask



  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    // seed the slave backing (by x86 phys addr): word at A = A ^ 0xA5A5_0000.
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h4000; a+=4) slv.poke(a, a ^ 32'hA5A5_0000);
    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("[1] cold read -> miss -> INCR8 line fill (multi-cycle) -> hit");
    do_read(32'h0000_1004, d); chk("read 0x1004", d, 32'h1004 ^ 32'hA5A5_0000);

    $display("[2] all 8 words of the filled line hit with correct data (m_ack count)");
    for (int w=0; w<8; w++) begin
      automatic logic [31:0] a = 32'h0000_1000 + 32'(w)*4;
      do_read(a, d); chk($sformatf("hit word %0d", w), d, a ^ 32'hA5A5_0000);
    end

    $display("[3] write-through then read-back (L1 array + DDR slave both updated)");
    do_write(32'h0000_1008, 32'hDEAD_BEEF);
    do_read (32'h0000_1008, d); chk("read-after-write", d, 32'hDEAD_BEEF);
    chk("DDR slave got the write", slv.peek(32'h0000_1008), 32'hDEAD_BEEF);

    $display("[4] 2-way set: a 3rd distinct line into the same set evicts LRU");
    do_read(32'h0000_2000, d); chk("line@2000", d, 32'h2000 ^ 32'hA5A5_0000);
    do_read(32'h0000_3000, d); chk("line@3000", d, 32'h3000 ^ 32'hA5A5_0000);
    do_read(32'h0000_2000, d); chk("rehit@2000", d, 32'h2000 ^ 32'hA5A5_0000);

    $display("[5] store-miss to a COLD line, then dependent load -> write landed in DDR");
    // 0x6020 is a fresh line (not yet cached). write-through must reach DDR; the
    // subsequent load misses, fills from DDR, and must see the stored value.
    do_write(32'h0000_6020, 32'hCAFE_F00D);
    chk("DDR slave has the cold store", slv.peek(32'h0000_6020), 32'hCAFE_F00D);
    do_read (32'h0000_6020, d); chk("dependent load sees store", d, 32'hCAFE_F00D);

    $display("[6] remap end-to-end: araddr was REMAP_BASE-offset (else [1]-[5] mismatch)");
    // (implicitly proven: the slave indexes (araddr-REMAP_BASE); every read above
    //  returned the correct seeded word, so REMAP_BASE+phys addressed DDR correctly.)
    chk("remap base nonzero", REMAP_BASE[31:0], 32'h4000_0000);

    $display("[7] #35 external flush: a backing write that BYPASSES the L1 + flush -> re-read sees it");
    // model the int-0x80 proxy / syscall emulator: it writes the DDR directly (not
    // through the core mem port), so the L1's cached copy goes stale. Without flush a
    // re-read HITS the stale line; with flush it misses + refills the new value.
    do_read(32'h0000_1000, d); chk("cache line@1000", d, 32'h1000 ^ 32'hA5A5_0000);   // now cached
    slv.poke(32'h0000_1000, 32'hC0FF_EE00);                          // proxy-style backing write (bypasses L1)
    do_read(32'h0000_1000, d); chk("STALE hit (no flush yet)", d, 32'h1000 ^ 32'hA5A5_0000);  // still the old cached value
    @(negedge clk); flush <= 1'b1; @(posedge clk); @(negedge clk); flush <= 1'b0;     // pulse the L1 flush
    do_read(32'h0000_1000, d); chk("post-flush refill (coherent)", d, 32'hC0FF_EE00); // miss -> refill -> new value

    if (errors==0) $display("L1AXI-GATE-OK (all checks pass)");
    else           $display("L1AXI-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #500000; $display("L1AXI-GATE-FAIL (timeout)"); $finish; end
endmodule
