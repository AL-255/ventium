// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_wd.sv — #34 watchdog/abort directed gate. ventium_l1_axi with a
// SMALL WATCHDOG, backed by a STUCK AXI slave (never responds). A read has no
// completion before it receives data. A P54C-style memory write may correctly receive
// c_ack on admission to one of its two bounded write buffers, then faults when the
// retained AXI write makes no progress. Both paths must raise bus_err. The complement
// (no false-fire under a normal slave) is covered by run-l1axi-gate.sh /
// run-l1axi-verify.sh at WATCHDOG=1024.

module tb_l1axi_wd;
  logic ic_nocache_unused;   // REVIEW2_aug2 H-13
  localparam int ADDR_W = 40;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        c_req=0, c_we=0; logic [31:0] c_addr=0, c_wdata=0; logic [3:0] c_wstrb=0;
  logic [31:0] c_rdata; logic c_ack, bus_err;

  // AXI master <-> STUCK slave
  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize;
  logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot;
  logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen; logic [2:0] arsize;
  logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot;
  logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'hFFFF_FFFF), .WATCHDOG(16)) dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .core_next_req(1'b0), .core_next_commit(1'b0),
      .core_next_addr(32'd0), .core_next_wstrb(4'd0), .core_next_ready(),
`endif

      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(1'b0),
      .smbase(32'h0003_0000), .smm_flush_o(), /* C-10 */ .core_lock(1'b0), .core_lock_hold(1'b0), /* REVIEW2_aug2 C-08: core reset default */ /* REVIEW2 H-24: no SMM in this unit gate */ .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      // REVIEW2_aug2 H-13: the I-side memory type. Not exercised by this
      // memory-subsystem gate; connected so the build stays warning-clean.
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
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

  axi_slave_bfm #(.ADDR_W(ADDR_W), .STUCK(1)) slv (   // STUCK: never responds
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  int errors = 0;
  // A buffered memory store retires into the fixed P54C queue before the AXI target
  // responds.  Deassert its producer request at that admission edge (as the core
  // does), then prove the retained transaction still times out rather than vanishing.
  task automatic stuck_access(input string what, input logic we, input logic [31:0] a);
    int g;
    @(negedge clk); c_req<=1'b1; c_we<=we; c_addr<=a; c_wdata<=32'hDEAD_0000; c_wstrb<=4'hF;
    g=0;
    if (we) begin
      while (!c_ack) begin
        @(posedge clk); #1;
        if (++g > 100) begin $display("  FAIL %s: write buffer never accepted store", what); errors++; break; end
      end
      if (c_ack) $display("  ok   %s accepted into bounded write buffer", what);
      @(negedge clk); c_req<=1'b0; c_we<=1'b0; c_wstrb<=4'd0;
      while (!bus_err) begin
        @(posedge clk); #1;
        if (++g > 300) begin $display("  FAIL %s: bus_err NEVER asserted after write admission", what); errors++; break; end
      end
      if (bus_err) $display("  ok   %s -> retained AXI write watchdog fired @%0d cyc", what, g);
    end else begin
      forever begin @(posedge clk); #1;
        if (bus_err) begin $display("  ok   %s -> watchdog fired: bus_err=1 @%0d cyc (c_ack=%b, AXI held)", what, g, c_ack); break; end
        if (c_ack)   begin $display("  FAIL %s: spurious c_ack with no bus_err (fake completion)", what); errors++; break; end
        if (++g > 300) begin $display("  FAIL %s: bus_err NEVER asserted (watchdog dead -> deadlock)", what); errors++; break; end
      end
      @(negedge clk); c_req<=1'b0; c_we<=1'b0;
    end
  endtask

  initial begin
    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);
    $display("[1] READ to a STUCK slave -> watchdog timeout -> bus_err (WATCHDOG=16)");
    stuck_access("read",  1'b0, 32'h0000_1000);
    // reset to clear the sticky bus_err, then test the WRITE watchdog (symmetric path).
    @(negedge clk); rst_n<=1'b0; repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);
    $display("[2] WRITE to a STUCK slave -> watchdog timeout -> bus_err");
    stuck_access("write", 1'b1, 32'h0000_2000);
    if (errors==0) $display("L1AXIWD-GATE-OK (watchdog raises bus_err; reads stall, buffered writes stay retained)");
    else           $display("L1AXIWD-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("L1AXIWD-GATE-FAIL (timeout — DEADLOCK)"); $finish; end
endmodule
