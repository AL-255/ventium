// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1l2.sv — Phase B integration gate for the L1 + **L2** + AXI subsystem
// (docs/northbridge-system-spec.md §5). Drives the CORE side of ventium_l1_axi built
// with EN_L2=1 (the ven_l2 UltraRAM L2 spliced into ven_l1d's backing seam) backed by
// a behavioral multi-cycle AXI4 DDR slave, and proves the L2 is a transparent, COHERENT
// drop-in that actually caches:
//   * functional: reads/writes through L1→L2→AXI return correct data;
//   * L2 HIT: read a line (L2 miss→DDR fill, 1 AR burst), flush the L1, re-read it —
//     the L1 misses but the L2 HITS, so the data is correct AND **no new AXI AR** is
//     issued (the whole point of the L2);
//   * WRITE-BACK: a dirty store absorbed by the L2 reaches DDR only on EVICTION — force
//     the eviction and observe the AXI **AW** writeback carrying the stored value.
// Cross-checked against ven_l2's VEN_DBG_CORE perf counters (surfaced via VEN_DBG_L2).
// Built with `verilator --binary` (+define+VEN_DBG_CORE +define+VEN_DBG_L2); prints
// L1L2-GATE-OK / L1L2-GATE-FAIL. Run via verif/l1/run-l1l2-gate.sh.

module tb_l1l2;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;
  // a TINY L2 so init is fast and evictions are easy to force: 2-way, 8 sets, 32B line
  // → 512 B, set index = addr[7:5], tag = addr[31:8].
  localparam int          L2_CAP     = 512;
  localparam int          L2_WAYS    = 2;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;

  // AXI master <-> slave
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
  logic        dbg_rd_valid; logic [31:0] dbg_rd_addr, dbg_rd_data;       // VEN_DBG_CORE
  logic        dbg_l2_ready; logic [31:0] dbg_l2_hits, dbg_l2_misses, dbg_l2_wbacks, dbg_l2_bypass; // VEN_DBG_L2

  // ---- AXI transaction counters (the structural proof of L2 caching) ---------
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
      .dbg_l2_ready(dbg_l2_ready), .dbg_l2_hits(dbg_l2_hits),
      .dbg_l2_misses(dbg_l2_misses), .dbg_l2_wbacks(dbg_l2_wbacks), .dbg_l2_bypass(dbg_l2_bypass),
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
    forever begin @(posedge clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 300) begin $display("  FAIL read %08x: no ack", a); errors++; d=32'hx; break; end
    end
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

  logic [31:0] d; int ar0, aw0;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [32:0] a=0; a<33'h4000; a+=4) slv.poke(a[31:0], a[31:0] ^ 32'hA5A5_0000);
    repeat(4) @(posedge clk); rst_n<=1'b1;
    // wait out the L2 init valid-clear walk before driving the core (the reset-gate
    // also holds the L1/core until this, but the gate samples it explicitly).
    begin int g; g=0;
      forever begin @(posedge clk); #1; if (dbg_l2_ready) break;
        if (++g > 1000) begin $display("  FAIL L2 never became ready"); errors++; break; end end
    end
    chk_int("L2 ready after init walk", dbg_l2_ready, 1);

    $display("[1] functional: cold read -> L2 miss -> DDR fill -> hit; whole line correct");
    do_read(32'h0000_1004, d); chk("read 0x1004", d, 32'h1004 ^ 32'hA5A5_0000);
    for (int w=0; w<8; w++) begin
      automatic logic [31:0] a = 32'h0000_1000 + 32'(w)*4;
      do_read(a, d); chk($sformatf("line word %0d", w), d, a ^ 32'hA5A5_0000);
    end

    $display("[2] write-through to L2 + read-back (L1+L2 coherent)");
    do_write(32'h0000_1008, 32'hDEAD_BEEF);
    do_read (32'h0000_1008, d); chk("read-after-write", d, 32'hDEAD_BEEF);

    $display("[3] L2 HIT after L1 flush: re-read issues NO new AXI AR (L2 serves it)");
    do_read(32'h0000_2000, d); chk("cold read 0x2000", d, 32'h2000 ^ 32'hA5A5_0000); // L2 fill (AR)
    do_flush();                                          // drop it from L1 only (L2 keeps it)
    ar0 = ar_count;
    do_read(32'h0000_2000, d); chk("re-read 0x2000 (L1 miss)", d, 32'h2000 ^ 32'hA5A5_0000);
    chk_int("no new AXI AR on L2 hit", ar_count - ar0, 0);   // <-- the L2 actually cached it

    $display("[4] WRITE-BACK: dirty store reaches DDR only on L2 eviction (AXI AW)");
    // A, B1, B2 all map to L2 set 0 (addr[7:5]=0), distinct tags; 2-way L2 → the 3rd
    // access evicts the LRU. Store A (dirty), then read 2 same-set lines to evict A.
    do_flush();                                          // clean slate in L1 (L2 still holds prior lines)
    do_write(32'h0000_1000, 32'hB10C_DA7A);              // A dirty in L2 (no DDR write yet)
    chk("DDR NOT yet written (write-back)", slv.peek(32'h0000_1000), 32'h1000 ^ 32'hA5A5_0000);
    aw0 = aw_count;
    do_read(32'h0000_1100, d); chk("evictor B1", d, 32'h1100 ^ 32'hA5A5_0000); // L2 set0 way fill
    do_read(32'h0000_1200, d); chk("evictor B2", d, 32'h1200 ^ 32'hA5A5_0000); // evicts dirty A -> AW
    repeat(8) @(posedge clk);                            // let the writeback B-response settle
    chk("dirty line written back to DDR", slv.peek(32'h0000_1000), 32'hB10C_DA7A);
    if (aw_count - aw0 < 1) begin $display("  FAIL no AXI AW writeback observed"); errors++; end
    else $display("  ok   AXI AW writeback observed (%0d)", aw_count - aw0);

    $display("[5] L2 perf counters sane (hits>0, misses>0, wbacks>0)");
    if (dbg_l2_hits   == 0) begin $display("  FAIL dbg_l2_hits==0");   errors++; end else $display("  ok   dbg_l2_hits = %0d", dbg_l2_hits);
    if (dbg_l2_misses == 0) begin $display("  FAIL dbg_l2_misses==0"); errors++; end else $display("  ok   dbg_l2_misses = %0d", dbg_l2_misses);
    if (dbg_l2_wbacks == 0) begin $display("  FAIL dbg_l2_wbacks==0"); errors++; end else $display("  ok   dbg_l2_wbacks = %0d", dbg_l2_wbacks);

    if (errors==0) $display("L1L2-GATE-OK (all checks pass)");
    else           $display("L1L2-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #500000; $display("L1L2-GATE-FAIL (timeout)"); $finish; end
endmodule
