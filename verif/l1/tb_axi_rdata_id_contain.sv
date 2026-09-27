// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Wrong-RID containment after an AR has already completed.
//
// The pre-AR RAR case in tb_axi_id_contain proves that a stale matching-ID R
// cannot be inherited at the address handshake.  This companion drives a
// wrong-ID, otherwise well-formed R beat while the master is in R_DATA, where
// RREADY is high and the beat would be most tempting to consume.  It then
// supplies three matching-ID/OKAY beats after the terminal fault to prove the
// master merely drains them: no L1 acknowledgement, replay, or new AR is legal
// until coupled reset.

module tb_axi_rdata_id_contain;
  localparam int unsigned ADDR_W = 40;
  localparam logic [31:0] PHYS = 32'h0000_1024;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  logic m_req, m_ack, bus_err, m_idle;
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
      .m_req(m_req), .m_we(1'b0), .m_addr(PHYS),
      .m_rd_narrow(1'b1), .m_rd_size(2'd2),
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

  typedef enum logic [1:0] { RESP_IDLE, RESP_BAD, RESP_GOOD } resp_state_e;
  resp_state_e resp_st;
  logic ar_seen;
  logic [2:0] good_left;
  assign awready = rst_n;
  assign wready  = rst_n;
  assign bid     = 4'd0;
  assign bresp   = 2'b00;
  assign bvalid  = 1'b0;
  // One AR is sufficient for this terminal-fault test.  A second would be the
  // defect, so do not provide a second slave-side address handshake.
  assign arready = rst_n && !ar_seen;
  assign rvalid  = (resp_st == RESP_BAD) || (resp_st == RESP_GOOD);
  assign rid     = (resp_st == RESP_BAD) ? 4'hA : 4'd0;
  assign rdata   = (resp_st == RESP_BAD) ? 32'hBAD0_1D00 : 32'hCAFE_0000;
  assign rresp   = 2'b00;
  assign rlast   = rvalid;  // narrow request: each response is one legal beat

  int errors;
  int ar_hs_count, bad_hs_count, good_hs_count, ack_count, err_low_count;
  int forbidden_write_count;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      resp_st <= RESP_IDLE;
      ar_seen <= 1'b0;
      good_left <= 3'd0;
      ar_hs_count <= 0;
      bad_hs_count <= 0;
      good_hs_count <= 0;
      ack_count <= 0;
      err_low_count <= 0;
      forbidden_write_count <= 0;
    end else begin
      if (arvalid && arready) begin
        ar_seen <= 1'b1;
        resp_st <= RESP_BAD;
        ar_hs_count <= ar_hs_count + 1;
      end
      if (rvalid && rready) begin
        if (resp_st == RESP_BAD) begin
          bad_hs_count <= bad_hs_count + 1;
          resp_st <= RESP_GOOD;
          good_left <= 3'd3;
        end else begin
          good_hs_count <= good_hs_count + 1;
          if (good_left == 3'd1) begin
            good_left <= 3'd0;
            resp_st <= RESP_IDLE;
          end else good_left <= good_left - 3'd1;
        end
      end
      if (rvalid && m_ack) ack_count <= ack_count + 1;
      if (rvalid && !bus_err) err_low_count <= err_low_count + 1;
      if (awvalid || wvalid) forbidden_write_count <= forbidden_write_count + 1;
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
    m_req = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk) m_req = 1'b1;

    guard = 0;
    while (bad_hs_count != 1 && guard < 80) begin
      @(posedge clk); #1;
      guard++;
    end
    if (bad_hs_count != 1) fail("wrong RID was not accepted in R_DATA");
    // Keep the request live through the three correctly formed follow-on beats.
    guard = 0;
    while (good_hs_count != 3 && guard < 80) begin
      @(posedge clk); #1;
      guard++;
    end
    @(negedge clk) m_req = 1'b0;
    repeat (2) @(posedge clk);

    if (ar_hs_count != 1)
      fail($sformatf("AR handshakes=%0d (expected exactly one)", ar_hs_count));
    if (good_hs_count != 3)
      fail($sformatf("post-fault matching response handshakes=%0d (expected 3)", good_hs_count));
    if (ack_count != 0)
      fail($sformatf("terminal R fault delivered %0d backing acknowledgement(s)", ack_count));
    if (err_low_count != 0 || bus_err !== 1'b1)
      fail($sformatf("bus_err not same-cycle/sticky low=%0d final=%b", err_low_count, bus_err));
    if (m_idle !== 1'b0)
      fail("terminal R fault incorrectly reported idle");
    if (forbidden_write_count != 0)
      fail($sformatf("terminal R fault launched %0d write-channel cycle(s)", forbidden_write_count));

    if (errors == 0)
      $display("AXI-RDATA-ID-CONTAIN-GATE-OK (wrong RID in R_DATA and later valid beats are drained only)");
    else
      $display("AXI-RDATA-ID-CONTAIN-GATE-FAIL (%0d error(s))", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("AXI-RDATA-ID-CONTAIN-GATE-FAIL (timeout)");
    $finish;
  end
endmodule : tb_axi_rdata_id_contain
