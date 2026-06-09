// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_wd.sv — #34 watchdog/abort directed gate. ventium_l1_axi with a
// SMALL WATCHDOG, backed by a STUCK AXI slave (never responds). A core read and a
// core write must each STILL COMPLETE (c_ack) instead of deadlocking — the master's
// watchdog times out, ABORTS (synthesizes ven_l1d's expected acks), and raises
// bus_err. Asserts L1AXIWD-GATE-OK. (The complement — no false-fire under a normal
// slave — is covered by run-l1axi-gate.sh / run-l1axi-verify.sh at WATCHDOG=1024.)

module tb_l1axi_wd;
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
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .core_wdata(c_wdata),
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
  // stuck access: the watchdog must raise bus_err within a bound. The AXI handshake
  // is HELD (a master can't retract VALID), so c_ack does NOT come at the L1 level —
  // in the real system the core's bus_err->S_HALT override abandons it + halts. So we
  // check: bus_err asserts (the watchdog fired) AND c_ack stayed 0 (no fake completion).
  task automatic stuck_access(input string what, input logic we, input logic [31:0] a);
    int g; @(negedge clk); c_req<=1'b1; c_we<=we; c_addr<=a; c_wdata<=32'hDEAD_0000; c_wstrb<=4'hF;
    g=0;
    forever begin @(posedge clk); #1;
      if (bus_err) begin $display("  ok   %s -> watchdog fired: bus_err=1 @%0d cyc (c_ack=%b, AXI held)", what, g, c_ack); break; end
      if (c_ack)   begin $display("  FAIL %s: spurious c_ack with no bus_err (fake completion)", what); errors++; break; end
      if (++g > 300) begin $display("  FAIL %s: bus_err NEVER asserted (watchdog dead -> deadlock)", what); errors++; break; end
    end
    @(negedge clk); c_req<=1'b0; c_we<=1'b0;
  endtask

  initial begin
    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);
    $display("[1] READ to a STUCK slave -> watchdog timeout -> bus_err (WATCHDOG=16)");
    stuck_access("read",  1'b0, 32'h0000_1000);
    // reset to clear the sticky bus_err, then test the WRITE watchdog (symmetric path).
    @(negedge clk); rst_n<=1'b0; repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);
    $display("[2] WRITE to a STUCK slave -> watchdog timeout -> bus_err");
    stuck_access("write", 1'b1, 32'h0000_2000);
    if (errors==0) $display("L1AXIWD-GATE-OK (watchdog raises bus_err; AXI handshake held, no fake ack)");
    else           $display("L1AXIWD-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("L1AXIWD-GATE-FAIL (timeout — DEADLOCK)"); $finish; end
endmodule
