// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l2_axi.sv — end-to-end faithfulness gate for ven_l2 against the REAL
// downstream master. Chains:
//
//   [L1-faithful driver] ─► ven_l2 ─(d_* backing)─► ven_axi_master ─► AXI4 ─► axi_slave_bfm
//
// This proves the L2's DOWNSTREAM port is a true drop-in for ven_l1d's master: the
// production ven_axi_master accepts the L2's fills (coalesced into one INCR8 burst)
// and dirty writebacks (single-beat writes) without modification, and the multi-cycle
// AXI slave (RD_LAT/WR_LAT + a mid-burst RVALID BUBBLE) exercises the L2's S_FILL
// dw-hold-on-bubble + real DDR latency. AXI AR/AW handshakes are counted to assert the
// latency-hiding behaviour at the bus level (an L2 hit issues NO AR; a write hit /
// write-allocate issues NO AW; a dirty eviction writes the line back). The 32→40-bit
// REMAP is in the loop (the slave un-remaps), so a wrong address fails. Builds with
// `verilator --binary`; prints L2AXI-GATE-OK / L2AXI-GATE-FAIL.

module tb_l2_axi;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;   // DDR carveout @ 1 GiB
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;      // 1 GiB window
  localparam int          ADDR_W     = 40;
  localparam int CAP=1024, LINE=32, WAYS=2, RDLAT=2;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // ---- upstream (driver ↔ L2) -----------------------------------------------
  logic        ready;
  logic        u_req, u_we; logic [31:0] u_addr, u_wdata; logic [3:0] u_wstrb;
  logic [31:0] u_rdata; logic u_ack;
  // ---- L2 ↔ ven_axi_master backing port -------------------------------------
  logic        d_req, d_we; logic [31:0] d_addr, d_wdata; logic [3:0] d_wstrb;
  logic [31:0] d_rdata; logic d_ack;
  // ---- AXI master ↔ slave ----------------------------------------------------
  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize;
  logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot;
  logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen; logic [2:0] arsize;
  logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot;
  logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;
  logic bus_err, m_idle;

  ven_l2 #(.L2_CAP_BYTES(CAP), .L2_LINE(LINE), .L2_WAYS(WAYS), .RAM_RD_LAT(RDLAT)) l2 (
      .clk, .rst_n, .ready,
      .u_req, .u_we, .u_addr, .u_wdata, .u_wstrb, .u_rdata, .u_ack,
      .d_req, .d_we, .d_addr, .d_wdata, .d_wstrb, .d_rdata, .d_ack);

  // the REAL downstream master (single-clock build): its backing slave m_* is driven
  // by the L2's d_* master port — exactly how ven_l1d.m_* drives it today.
  ven_axi_master #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK)) axm (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req(d_req), .m_we(d_we), .m_addr(d_addr), .m_wdata(d_wdata), .m_wstrb(d_wstrb),
      .m_rdata(d_rdata), .m_ack(d_ack), .bus_err(bus_err),
      .shutdown(1'b0), .m_idle(m_idle),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
      .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(4), .WR_LAT(3), .BUBBLE(1)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready));

  // ---- AXI handshake counters + idle quiesce ---------------------------------
  int ar_cnt=0, aw_cnt=0;
  bit AXTRACE=0; int axbudget=0;          // capture the real AXI DDR transactions
  always @(posedge clk) begin
    if (arvalid && arready) begin
      ar_cnt <= ar_cnt + 1;
      if (AXTRACE && axbudget>0) begin
        $display("    AXI AR  fill burst  @%010x  len=%0d (INCR%0d)", araddr, arlen, arlen+1);
        axbudget--; end
    end
    if (awvalid && awready) begin
      aw_cnt <= aw_cnt + 1;
      if (AXTRACE && axbudget>0) begin
        $display("    AXI AW  writeback   @%010x  (dirty line eviction)", awaddr);
        axbudget--; end
    end
  end
  task automatic axi_quiesce();   // wait until the whole L2+AXI path is idle
    int idle; idle=0;
    while (idle < 4) begin
      @(posedge clk); #1;
      if (d_req || arvalid || awvalid || rvalid || wvalid || bvalid) idle=0; else idle++;
    end
  endtask

  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic chk_int(input string what, input int got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask

  // L1-faithful fill: hold u_req, walk 8 line words, one ack each.
  task automatic l2_read(input logic [31:0] addr, output logic [31:0] w [8]);
    logic [31:0] base; int fw, guard;
    base = addr & ~32'h1F;
    @(negedge clk); u_req<=1'b1; u_we<=1'b0; u_wstrb<=4'd0; u_addr<=base;
    fw=0; guard=0;
    forever begin
      @(posedge clk); #1;
      if (u_ack) begin w[fw]=u_rdata; fw++; if (fw==8) break; u_addr<=base+32'(fw)*4; end
      if (++guard>600) begin $display("  FAIL read %08x: only %0d words", addr, fw); errors++; break; end
    end
    @(negedge clk); u_req<=1'b0;
    axi_quiesce();
  endtask
  task automatic l2_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    int guard;
    @(negedge clk); u_req<=1'b1; u_we<=1'b1; u_addr<=addr; u_wdata<=data; u_wstrb<=strb;
    guard=0;
    forever begin @(posedge clk); #1; if (u_ack) break;
      if (++guard>600) begin $display("  FAIL write %08x: no ack", addr); errors++; break; end end
    @(negedge clk); u_req<=1'b0; u_we<=1'b0;
    axi_quiesce();
  endtask
  task automatic rd_check_line(input string tag, input logic [31:0] base, input logic [31:0] xp);
    logic [31:0] w [8];
    l2_read(base, w);
    for (int i=0;i<8;i++) chk($sformatf("%s w%0d", tag, i), w[i], (base+32'(i)*4) ^ xp);
  endtask

  logic [31:0] w [8]; int a0, b0;
  initial begin
    u_req=0; u_we=0; u_addr=0; u_wdata=0; u_wstrb=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h2000; a+=4) slv.poke(a, a ^ 32'hA5A5_0000);
    repeat(4) @(posedge clk); rst_n<=1'b1;
    wait (ready===1'b1); @(posedge clk);
    $display("[init] L2 ready");

    $display("[1] cold read -> ONE INCR8 burst through ven_axi_master -> 8 words");
    a0=ar_cnt; rd_check_line("cold@0x40", 32'h0000_0040, 32'hA5A5_0000);
    chk_int("AXI AR bursts for a cold fill", ar_cnt-a0, 1);

    $display("[2] re-read -> L2 HIT -> ZERO AXI reads (DDR latency hidden)");
    a0=ar_cnt; rd_check_line("hit@0x40", 32'h0000_0040, 32'hA5A5_0000);
    chk_int("AXI AR bursts for an L2 hit", ar_cnt-a0, 0);

    $display("[3] write HIT -> write-back: ZERO AXI writes");
    b0=aw_cnt;
    l2_write(32'h0000_0048, 32'hDEAD_BEEF, 4'hF);
    chk_int("AXI AW for a write hit", aw_cnt-b0, 0);
    l2_read(32'h0000_0040, w); chk("read-after-write @0x48", w[2], 32'hDEAD_BEEF);
    chk("DDR slave still OLD @0x48 (write-back)", slv.peek(32'h48), 32'h48 ^ 32'hA5A5_0000);

    $display("[4] DIRTY eviction -> line written back through real AXI, byte-correct");
    rd_check_line("D@0x620", 32'h0000_0620, 32'hA5A5_0000);
    l2_write(32'h0000_0620, 32'h1234_5678, 4'hF);          // dirty
    rd_check_line("E@0x820", 32'h0000_0820, 32'hA5A5_0000);
    b0=aw_cnt;
    rd_check_line("F@0xA20", 32'h0000_0A20, 32'hA5A5_0000); // evict 0x620 (dirty)
    chk_int("AXI AW writes on a dirty eviction (8 words)", aw_cnt-b0, 8);
    chk("writeback landed in DDR @0x620", slv.peek(32'h620), 32'h1234_5678);
    chk("writeback kept the rest @0x624", slv.peek(32'h624), 32'h624 ^ 32'hA5A5_0000);

    $display("[5] write-allocate on a write MISS -> AXI fill, deferred write");
    a0=ar_cnt; b0=aw_cnt;
    l2_write(32'h0000_0C04, 32'hCAFE_F00D, 4'hF);
    chk_int("AXI AR to allocate", ar_cnt-a0, 1);
    chk_int("AXI AW on write-allocate (deferred)", aw_cnt-b0, 0);
    l2_read(32'h0000_0C00, w); chk("write-allocate read-back @0xC04", w[1], 32'hCAFE_F00D);

    $display("[6] CROSS-LINE straddle store through the real path");
    rd_check_line("pre L @0xE00", 32'h0000_0E00, 32'hA5A5_0000);
    rd_check_line("pre L+1 @0xE20", 32'h0000_0E20, 32'hA5A5_0000);
    l2_write(32'h0000_0E1E, 32'h4433_2211, 4'hF);
    l2_read(32'h0000_0E00, w); chk("straddle L word7", w[7][31:16], 16'h2211);
    l2_read(32'h0000_0E20, w); chk("straddle L+1 word0", w[0][15:0], 16'h4433);

    // ------------------------------------------------------------------ [7]
    $display("[7] CAPACITY OVERRUN through the real AXI master: 4x working set");
    $display("    writes thrash the 32-line cache -> fills = INCR8 AR bursts, dirty");
    $display("    evictions = AW writebacks; read-back proves no data lost over AXI");
    begin
      automatic int NL = 4*32;                 // 4x the 32-line capacity
      logic [31:0] exp0 [0:255];
      AXTRACE=1; axbudget=20; a0=ar_cnt; b0=aw_cnt;
      for (int i=0;i<NL;i++) begin
        exp0[i] = 32'h7000_0000 | 32'(i);
        l2_write(32'(i)*32, exp0[i], 4'hF);    // word0 of line i, dirty
      end
      AXTRACE=0;
      $display("    write-overrun: AR(fills)=%0d  AW(writebacks)=%0d", ar_cnt-a0, aw_cnt-b0);
      chk_int("overrun produced dirty writebacks over AXI (AW>0)", (aw_cnt-b0)>0, 1);
      a0=ar_cnt;
      for (int i=0;i<NL;i++) begin
        l2_read(32'(i)*32, w);
        chk($sformatf("overrun read-back line %0d word0", i), w[0], exp0[i]);
      end
      $display("    read-back: AR(refills)=%0d (every evicted line refilled from DDR)", ar_cnt-a0);
    end

    chk("no bus_err through the run", {31'd0, bus_err}, 32'd0);

    if (errors==0) $display("L2AXI-GATE-OK (all checks pass)");
    else           $display("L2AXI-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #3000000; $display("L2AXI-GATE-FAIL (timeout)"); $finish; end
endmodule
