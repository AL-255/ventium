// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Direct ven_axi_master BRESP containment regression.
//
// A P54C store normally retires when it enters one of the two retained write
// buffers; the later AXI BRESP cannot undo that architectural admission.  It
// MUST, however, prevent an unrelated second request from being admitted on
// the exact B handshake where the first store reports SLVERR.  Waiting one
// clock for sticky bresp_err is too late: a second held store can otherwise
// enter a free buffer slot on the error edge.
//
// This intentionally small direct test owns a protocol-correct AXI responder:
// AW/W are accepted independently and the sole SLVERR B response is registered
// only AFTER the first write beat has handshaken.  While that response is held,
// the backing requester holds a second aligned store.  On the bad B handshake
// the test requires bus_err=1 and m_ack=0, then proves the second store never
// reaches AW/W, the first write drains cleanly, and bus_err remains sticky.
//
// The gate keeps assertions enabled and defines VEN_AXI_RESP_FAULT_INJECT, which
// suppresses only the deliberate response-status assumptions for this fault stimulus.
// Ordinary builds continue to enforce OKAY BRESP.

module tb_axi_bresp_contain;
  localparam int unsigned ADDR_W = 40;
  localparam logic [31:0] FIRST_ADDR  = 32'h0000_1200;
  localparam logic [31:0] SECOND_ADDR = 32'h0000_1204;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // Backing-side producer.  This is deliberately a bare master seam rather
  // than ven_l1d: it makes the simultaneous B-response/admission boundary
  // directly observable as m_ack.
  logic        m_req = 1'b0;
  logic        m_we  = 1'b0;
  logic [31:0] m_addr = 32'd0;
  logic [31:0] m_wdata = 32'd0;
  logic [3:0]  m_wstrb = 4'd0;
  logic [31:0] m_rdata;
  logic        m_ack, bus_err, m_idle;

  // AXI channel wires.
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

  ven_axi_master #(
      .ADDR_W(ADDR_W), .WATCHDOG(128)
  ) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
      .m_rd_narrow(1'b0), .m_rd_size(2'd2),
      .m_wdata(m_wdata), .m_wstrb(m_wstrb),
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

  // The responder is AXI-compliant: READY is independent of VALID, and each
  // accepted single-beat AW/W pair contributes one pending B response.  Keeping
  // a small count (rather than a BVALID set/clear flop) preserves a queued
  // response when an unsafe second AW/W pair arrives on the same edge that the
  // first B handshakes.  Both channels are ready in this focused test, so the
  // P5 store's one AXI beat must handshake together; an implementation that
  // does not do so is reported by the monitor.
  assign awready = rst_n;
  assign wready  = rst_n;
  assign bid     = 4'd0;
  assign bresp   = bvalid ? 2'b10 : 2'b00;  // queued B responses are SLVERR

  // No read is requested in this test.  These idle values keep all unused AXI
  // channels legal rather than leaving a fake responder signal unknown.
  assign arready = rst_n;
  assign rid     = 4'd0;
  assign rdata   = 32'd0;
  assign rresp   = 2'b00;
  assign rlast   = 1'b0;
  assign rvalid  = 1'b0;

  logic first_axi_write_seen;
  logic b_fault_hs_seen;
  logic second_req_live = 1'b0;
  logic [2:0] pending_b_count = 3'd0;
  int aw_hs_count, w_hs_count, b_hs_count;
  int first_ack_count, first_ack_buserr_count, second_ack_count;
  int fault_buserr_low_count, fault_m_ack_high_count, bresp_shape_bad_count;

  // AXI responder state.  A second AW/W, if an unsafe implementation admitted
  // the held request, receives a response too so the test can drain and report
  // the protocol violation rather than hiding it behind a deliberately wedged
  // fake slave.  The expected result nevertheless remains exactly one AW/W/B.
  // All queued responses are SLVERR: the expected run has only the first one;
  // an illicit additional write is still given a legal, drainable response.
  assign bvalid = (pending_b_count != 3'd0);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      first_axi_write_seen <= 1'b0;
      b_fault_hs_seen     <= 1'b0;
      pending_b_count     <= 3'd0;
    end else begin
      if (awvalid && awready && wvalid && wready) begin
        first_axi_write_seen <= 1'b1;
      end
      if (bvalid && bready) begin
        b_fault_hs_seen <= 1'b1;
      end
      case ({(awvalid && awready && wvalid && wready), (bvalid && bready)})
        2'b10: pending_b_count <= pending_b_count + 3'd1;
        2'b01: pending_b_count <= pending_b_count - 3'd1;
        default: pending_b_count <= pending_b_count;
      endcase
    end
  end

  // Score the values visible *on* the active clock edge.  This is intentional:
  // bresp_err is sticky state updated after the handshake, whereas bus_err and
  // m_ack must already reflect the raw SLVERR on this same edge.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_hs_count             <= 0;
      w_hs_count              <= 0;
      b_hs_count              <= 0;
      first_ack_count         <= 0;
      first_ack_buserr_count  <= 0;
      second_ack_count        <= 0;
      fault_buserr_low_count  <= 0;
      fault_m_ack_high_count  <= 0;
      bresp_shape_bad_count   <= 0;
    end else begin
      if (awvalid && awready) aw_hs_count <= aw_hs_count + 1;
      if (wvalid && wready)   w_hs_count  <= w_hs_count + 1;
      if (!second_req_live && m_req && m_we && m_ack) begin
        first_ack_count <= first_ack_count + 1;
        if (bus_err !== 1'b0) first_ack_buserr_count <= first_ack_buserr_count + 1;
      end
      if (second_req_live && m_ack) second_ack_count <= second_ack_count + 1;
      if (bvalid && bready) begin
        b_hs_count <= b_hs_count + 1;
        if (bresp !== 2'b10) bresp_shape_bad_count <= bresp_shape_bad_count + 1;
        if (bus_err !== 1'b1) fault_buserr_low_count <= fault_buserr_low_count + 1;
        if (m_ack !== 1'b0) fault_m_ack_high_count <= fault_m_ack_high_count + 1;
      end
    end
  end

  logic first_admission_timeout, first_axi_timeout, b_fault_timeout, idle_timeout;
  logic test_done = 1'b0;

  initial begin : stimulus
    int guard;
    first_admission_timeout = 1'b0;
    first_axi_timeout       = 1'b0;
    b_fault_timeout         = 1'b0;
    idle_timeout            = 1'b0;

    repeat (5) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // First store: prove ordinary P54C posting remains intact before injecting
    // the later response fault.
    @(negedge clk);
    m_req = 1'b1; m_we = 1'b1; m_addr = FIRST_ADDR;
    m_wdata = 32'h1111_2222; m_wstrb = 4'hF;
    guard = 0;
    while (!m_ack && (guard < 80)) begin
      @(posedge clk); #1;
      guard++;
    end
    if (!m_ack) begin
      $display("FAIL: first posted store was not admitted");
      first_admission_timeout = 1'b1;
    end
    @(negedge clk);
    m_req = 1'b0; m_we = 1'b0; m_wstrb = 4'd0;

    // Wait for the first write beat to have truly crossed AW/W.  BVALID has been
    // registered by the responder at this point, so the next positive edge is
    // necessarily the faulting B handshake while the second request is live.
    guard = 0;
    while (!first_axi_write_seen && (guard < 80)) begin
      @(posedge clk); #1;
      guard++;
    end
    if (!first_axi_write_seen) begin
      $display("FAIL: first admitted store never reached AXI AW/W");
      first_axi_timeout = 1'b1;
    end else begin
      @(negedge clk);
      second_req_live = 1'b1;
      m_req = 1'b1; m_we = 1'b1; m_addr = SECOND_ADDR;
      m_wdata = 32'h3333_4444; m_wstrb = 4'hF;

      guard = 0;
      while (!b_fault_hs_seen && (guard < 40)) begin
        @(posedge clk); #1;
        guard++;
      end
      if (!b_fault_hs_seen) begin
        $display("FAIL: registered SLVERR B response never handshook");
        b_fault_timeout = 1'b1;
      end
      @(negedge clk);
      // The second request was deliberately present through the bad B edge.
      // Drop it now, as the real producer would once bus_err takes precedence.
      m_req = 1'b0; m_we = 1'b0; m_wstrb = 4'd0; second_req_live = 1'b0;
    end

    guard = 0;
    while (!m_idle && (guard < 80)) begin
      @(posedge clk); #1;
      guard++;
    end
    if (!m_idle) begin
      $display("FAIL: master did not return to idle after BRESP drain");
      idle_timeout = 1'b1;
    end
    // Extra quiet edges catch a delayed, illicit second AW/W after the error.
    repeat (3) @(posedge clk);
    test_done = 1'b1;
  end

  initial begin : report
    int failures;
    wait (test_done);
    failures = 0;
    if (first_admission_timeout || first_axi_timeout || b_fault_timeout || idle_timeout)
      failures++;
    if (first_ack_count != 1 || first_ack_buserr_count != 0) begin
      $display("FAIL: first posted-store admission count=%0d buserr_at_admission=%0d (exp 1/0)",
               first_ack_count, first_ack_buserr_count);
      failures++;
    end
    if (b_hs_count != 1 || bresp_shape_bad_count != 0) begin
      $display("FAIL: B response count=%0d bad-shape=%0d (exp 1/0)",
               b_hs_count, bresp_shape_bad_count);
      failures++;
    end
    if (fault_buserr_low_count != 0 || fault_m_ack_high_count != 0 || second_ack_count != 0) begin
      $display("FAIL: same-edge containment buserr_low=%0d m_ack_high=%0d second_ack=%0d",
               fault_buserr_low_count, fault_m_ack_high_count, second_ack_count);
      failures++;
    end
    if (aw_hs_count != 1 || w_hs_count != 1) begin
      $display("FAIL: second store reached AXI (AW=%0d W=%0d; exp exactly 1/1)",
               aw_hs_count, w_hs_count);
      failures++;
    end
    if (bus_err !== 1'b1) begin
      $display("FAIL: BRESP bus_err did not remain sticky");
      failures++;
    end
    if (!m_idle) begin
      $display("FAIL: master left non-idle after quiet drain window");
      failures++;
    end
    if (failures == 0)
      $display("AXI-BRESP-CONTAIN-GATE-OK (same-edge SLVERR blocks held follow-on store)");
    else
      $display("AXI-BRESP-CONTAIN-GATE-FAIL (%0d failures)", failures);
    $finish;
  end

  initial begin
    #100000;
    $display("AXI-BRESP-CONTAIN-GATE-FAIL (timeout)");
    $finish;
  end
endmodule
