// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Matching-ID orphan-B containment regression.
//
// A reusable fixed AXI ID cannot rely on the ID alone to own a write response:
// a matching BID with no AW/W pair outstanding is still stale or misrouted. The
// first beat must fault before BREADY is raised; thereafter the terminal state
// drains three otherwise-OKAY responses without releasing a P5 write slot or
// advertising m_idle.

module tb_axi_orphan_b_contain;
  localparam int unsigned ADDR_W = 40;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  logic m_ack, bus_err, m_idle;
  logic [31:0] m_rdata;
  logic [3:0] awid, arid, bid, rid;
  logic [ADDR_W-1:0] awaddr, araddr;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst;
  logic awlock, arlock;
  logic [3:0] awcache, arcache, awqos, arqos;
  logic [2:0] awprot, arprot;
  logic awvalid, awready, wvalid, wready, wlast;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic bvalid, bready, arvalid, arready, rvalid, rready, rlast;
  logic [1:0] bresp, rresp;

  ven_axi_master #(.ADDR_W(ADDR_W), .WATCHDOG(64)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req(1'b0), .m_we(1'b0), .m_addr(32'd0),
      .m_rd_narrow(1'b0), .m_rd_size(2'd2),
      .m_wdata(32'd0), .m_wstrb(4'd0),
      .m_rdata(m_rdata), .m_ack(m_ack), .bus_err(bus_err),
      .shutdown(1'b0), .m_idle(m_idle),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
      .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
      .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
      .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready),
      .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  logic [2:0] b_left;
  assign awready = rst_n;
  assign wready  = rst_n;
  assign bid     = 4'd0;       // matching, but there is no outstanding command
  assign bresp   = 2'b00;
  assign bvalid  = (b_left != 3'd0);
  assign arready = rst_n;
  assign rid     = 4'd0;
  assign rdata   = 32'd0;
  assign rresp   = 2'b00;
  assign rlast   = 1'b0;
  assign rvalid  = 1'b0;

  int errors;
  int b_hs_count, bready_low_count, ack_count, err_low_count, traffic_count;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      b_left <= 3'd0;
      b_hs_count <= 0;
      bready_low_count <= 0;
      ack_count <= 0;
      err_low_count <= 0;
      traffic_count <= 0;
    end else begin
      if (bvalid && !bready) bready_low_count <= bready_low_count + 1;
      if (bvalid && bready) begin
        b_hs_count <= b_hs_count + 1;
        b_left <= b_left - 3'd1;
      end
      if (bvalid && m_ack) ack_count <= ack_count + 1;
      if (bvalid && !bus_err) err_low_count <= err_low_count + 1;
      if (awvalid || wvalid || arvalid) traffic_count <= traffic_count + 1;
    end
  end

  task automatic fail(input string what);
    begin
      $display("  FAIL: %s", what);
      errors = errors + 1;
    end
  endtask

  initial begin : stimulus
    int guard;
    errors = 0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (2) @(posedge clk);
    // Hold the first orphan beat before the master has ever owned B, then
    // continue with two matching-ID beats after it enters terminal drain.
    @(negedge clk) b_left = 3'd3;
    guard = 0;
    while (b_hs_count != 3 && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    repeat (2) @(posedge clk);

    if (b_hs_count != 3)
      fail($sformatf("drained matching orphan B handshakes=%0d (expected 3)", b_hs_count));
    if (bready_low_count == 0)
      fail("first matching orphan B was accepted before ownership fault latched");
    if (ack_count != 0)
      fail($sformatf("orphan B generated %0d backing acknowledgement(s)", ack_count));
    if (err_low_count != 0 || bus_err !== 1'b1)
      fail($sformatf("bus_err not same-cycle/sticky low=%0d final=%b", err_low_count, bus_err));
    if (m_idle !== 1'b0)
      fail("matching orphan B incorrectly reported idle");
    if (traffic_count != 0)
      fail($sformatf("orphan B launched %0d AXI request-channel cycle(s)", traffic_count));

    if (errors == 0)
      $display("AXI-ORPHAN-B-CONTAIN-GATE-OK (matching orphan B faults then drains without retirement)");
    else
      $display("AXI-ORPHAN-B-CONTAIN-GATE-FAIL (%0d error(s))", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("AXI-ORPHAN-B-CONTAIN-GATE-FAIL (timeout)");
    $finish;
  end
endmodule : tb_axi_orphan_b_contain
