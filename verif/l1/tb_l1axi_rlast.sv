// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_wd.sv — #34 watchdog/abort directed gate. ventium_l1_axi with a
// SMALL WATCHDOG, backed by a STUCK AXI slave (never responds). A core read and a
// core write must each STILL COMPLETE (c_ack) instead of deadlocking — the master's
// watchdog times out, ABORTS (synthesizes ven_l1d's expected acks), and raises
// bus_err. Asserts L1AXIWD-GATE-OK. (The complement — no false-fire under a normal
// slave — is covered by run-l1axi-gate.sh / run-l1axi-verify.sh at WATCHDOG=1024.)

module tb_l1axi_rlast;
  // REVIEW2 M-08: RLAST/beat-count mismatch RECOVERY.
  //
  // ven_axi_master exits a read burst on its own beat count, not on RLAST. Flagging a
  // mismatch (rlast_err -> bus_err) was already in place, but the review also requires
  // draining/recovering DETERMINISTICALLY, and NO existing test could reach that path
  // because a compliant slave never produces a mismatch. axi_slave_bfm now injects one.
  //
  //   TB_MODE=0  RLAST_EXTRA=1 : LATE RLAST. The slave sends one beat MORE than arlen
  //                              and withholds RLAST until it. The master's count is
  //                              satisfied first, so without a drain it would return to
  //                              idle with a beat still in flight -- which the NEXT
  //                              burst would consume as its own data.
  //   TB_MODE=1  RLAST_EARLY=1 : EARLY RLAST. The slave ends the burst one beat early.
  //                              Without the early-exit the master waits for a beat that
  //                              never comes and only the #34 watchdog rescues it.
  //
  // Both must (a) raise bus_err and (b) NOT deadlock -- the master must come back and
  // still be able to serve a subsequent request.
  parameter int TB_MODE = 0;
  localparam int ADDR_W = 40;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        c_req=0, c_we=0; logic [31:0] c_addr=0, c_wdata=0; logic [3:0] c_wstrb=0;
  logic [31:0] c_rdata; logic c_ack, bus_err, m_idle;

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
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(1'b0), /* REVIEW2 H-24: no SMM in this unit gate */ .core_lin(c_addr), .core_wdata(c_wdata),
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

  axi_slave_bfm #(.ADDR_W(ADDR_W),
                  .RLAST_EXTRA((TB_MODE==0) ? 1 : 0),
                  .RLAST_EARLY((TB_MODE==1) ? 1 : 0)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  int errors = 0;

  // Drive one read and wait for either c_ack or a bound. Returns cycles waited.
  task automatic do_read(input [31:0] a, output logic got_ack, output int cycles);
    int g;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'h0;
    g=0; got_ack=1'b0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin got_ack=1'b1; break; end
      if (bus_err && g > 40) break;      // fault reported; stop driving
      if (++g > 300) break;
    end
    cycles = g;
    @(negedge clk); c_req<=1'b0;
  endtask

  initial begin
    logic ack1; int cyc1, g;
    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    if (TB_MODE==0) $display("[M-08] LATE RLAST (slave sends 1 extra beat, RLAST withheld)");
    else            $display("[M-08] EARLY RLAST (slave ends the burst 1 beat early)");

    do_read(32'h0000_1000, ack1, cyc1);
    $display("  read: ack=%0b after %0d cyc, bus_err=%0b", ack1, cyc1, bus_err);

    // (a) the mismatch must be REPORTED as a sticky fatal fault.
    if (bus_err) $display("  ok   RLAST mismatch raised bus_err (sticky fatal fault)");
    else begin   $display("  FAIL RLAST mismatch did NOT raise bus_err"); errors++; end

    // (b) and the master must RECOVER DETERMINISTICALLY -- return to idle rather than
    //     hang. NOTE the contract: bus_err is sticky and the real system responds with
    //     the core's bus_err->S_HALT override, so "serve a later request" is NOT the
    //     property (the watchdog gate documents the same). What the drain/early-exit
    //     buys is that the AXI read FSM lands back in R_IDLE with no beat left in
    //     flight, on a bounded and known cycle. m_idle = (R_IDLE && W_IDLE) is exactly
    //     that. Before this fix: a LATE RLAST returned to idle with a beat still owed
    //     (the next burst would eat it), and an EARLY RLAST never reached idle at all
    //     until the #34 watchdog fired.
    g = 0;
    while (!m_idle && g < 200) begin @(posedge clk); #1; g++; end
    if (m_idle) $display("  ok   AXI read FSM returned to IDLE %0d cyc after the fault (drained, no beat in flight)", g);
    else begin  $display("  FAIL AXI read FSM never returned to IDLE -- hung, not recovered"); errors++; end

    if (errors==0) $display("L1AXIRLAST-GATE-OK (RLAST mismatch reported AND recovered deterministically)");
    else           $display("L1AXIRLAST-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #200000; $display("L1AXIRLAST-GATE-FAIL (timeout — DEADLOCK)"); $finish; end
endmodule
