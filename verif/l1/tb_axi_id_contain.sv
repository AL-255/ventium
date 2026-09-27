// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Direct ven_axi_master AXI response-ID containment regression.
//
// The master emits exactly one AXI ID.  An R/B response carrying another ID is
// not an owned SLVERR: accepting it would advance a line-fill counter or release
// a P54C write-buffer slot for a transaction that did not complete.  This test
// injects protocol-illegal but safety-critical wrong-ID responses and requires:
//
//   * same-cycle bus_err and no backing m_ack;
//   * the malformed AXI response still handshakes (no AXI input->output READY
//     feedback / no wedged shared channel), but it never advances local state;
//   * the owned request remains outstanding (m_idle=0) until the platform reset.
//
// Unlike the RRESP/BRESP containment test, RETIREMENT is the wrong result: the
// master cannot safely decide which real request a foreign response displaced.
// The runner defines VEN_AXI_FAULT_INJECT to suppress only the deliberately
// violated ownership assumptions; VALID-stability and containment assertions
// remain active throughout this malformed-stimulus test.

module axi_rid_contain_case #(
    parameter bit START_WRONG_ID = 1'b1,
    parameter bit STALL_AR       = 1'b1
) (
    input logic clk,
    input logic rst_n,
    output logic done,
    output int   errs
);
  localparam int unsigned ADDR_W = 40;
  localparam logic [31:0] PHYS = 32'h0000_1024;
  // Each fault case proves its own coupled-reset recovery without disturbing
  // the sibling case sharing the test clock.
  logic fault_reset = 1'b0;
  logic fault_id;
  wire dut_rst_n = rst_n && !fault_reset;

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

  ven_axi_master #(
      .ADDR_W(ADDR_W), .WATCHDOG(64)
  ) dut (
      .core_clk(clk), .core_rst_n(dut_rst_n), .axi_clk(clk), .axi_rst_n(dut_rst_n),
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

  // A one-beat, otherwise-legal response with an ID this master never issued.
  // It is held until the fault state drains it; that drain must not turn it into
  // an L1 acknowledgment or alter the pending AR's state/accounting.
  logic r_pending;
  logic ar_stall = 1'b0;
  logic stray_rvalid = 1'b0;
  assign awready = dut_rst_n;
  assign wready  = dut_rst_n;
  assign bid     = 4'd0;
  assign bresp   = 2'b00;
  assign bvalid  = 1'b0;
  assign arready = dut_rst_n && !r_pending && !ar_stall;
  assign rid     = fault_id ? 4'hA : 4'd0;
  assign rdata   = 32'hBAD0_1D00;
  assign rresp   = 2'b00;
  // `stray_rvalid` is the injected response independently of its ID.  This
  // lets the second instance prove the subtle same-ID case: a response before
  // the AR handshake belongs to no request even when RID happens to be zero.
  assign rlast   = stray_rvalid ? 1'b1 : r_pending;
  assign rvalid  = stray_rvalid ? 1'b1 : r_pending;

  int ar_hs_count, r_hs_count, rready_high_count, ack_count, buserr_low_count;
  logic fault_seen;
  always_ff @(posedge clk) begin
    if (!dut_rst_n) begin
      r_pending         <= 1'b0;
      stray_rvalid      <= 1'b0;
      ar_hs_count       <= 0;
      r_hs_count        <= 0;
      rready_high_count <= 0;
      ack_count         <= 0;
      buserr_low_count  <= 0;
      fault_seen        <= 1'b0;
    end else begin
      if (arvalid && arready) begin
        // Do not manufacture the normal response for the same cycle in which
        // this BFM deliberately injects a pre-AR stale response.
        if (!fault_id && !stray_rvalid) r_pending <= 1'b1;
        ar_hs_count <= ar_hs_count + 1;
      end
      if (stray_rvalid && rready) stray_rvalid <= 1'b0;
      if (!stray_rvalid && !fault_id && rvalid && rready) r_pending <= 1'b0;
      if (rvalid) begin
        fault_seen <= 1'b1;
        if (rready !== 1'b0) rready_high_count <= rready_high_count + 1;
        if (rvalid && rready) r_hs_count <= r_hs_count + 1;
        if (m_ack !== 1'b0) ack_count <= ack_count + 1;
        if (bus_err !== 1'b1) buserr_low_count <= buserr_low_count + 1;
      end
    end
  end

  initial begin : run_rid_case
    int guard;
    int local_errs;
    m_req = 1'b0;
    fault_id = START_WRONG_ID;
    done = 1'b0;
    errs = 0;
    local_errs = 0;
    wait (dut_rst_n === 1'b1);
    repeat (2) @(posedge clk);
    @(negedge clk) m_req = 1'b1;
    // Let R_IDLE register the AR, then inject a response before the address
    // request owns an R channel.  The RID case also deliberately stalls ARREADY
    // to prove ARVALID/payload stability; the RAR case leaves it high so RVALID
    // is concurrent with the first AR handshake and has the *matching* ID.
    @(posedge clk);
    @(negedge clk) begin
      ar_stall = STALL_AR;
      stray_rvalid = 1'b1;
    end
    if (STALL_AR) begin
      repeat (2) @(posedge clk);
      #1;
      if (arvalid !== 1'b1 || ar_hs_count != 0 || araddr !== 40'h0_0000_1024) begin
        $display("FAIL [RID]: ARVALID/address not held through bad-R stall valid=%b hs=%0d addr=%010x",
                 arvalid, ar_hs_count, araddr);
        local_errs++;
      end
      @(negedge clk) ar_stall = 1'b0;
    end
    guard = 0;
    while (!fault_seen && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    @(negedge clk) m_req = 1'b0;
    repeat (3) @(posedge clk);
    #1;

    if (!fault_seen) begin
      $display("FAIL [%s]: injected pre-AR R response was never presented",
               START_WRONG_ID ? "RID" : "RAR");
      local_errs++;
    end
    if (ar_hs_count != 1) begin
      $display("FAIL [%s]: AR handshakes=%0d (exp 1)",
               START_WRONG_ID ? "RID" : "RAR", ar_hs_count);
      local_errs++;
    end
    if (r_hs_count != 1 || rready_high_count != 1 || ack_count != 0) begin
      $display("FAIL [%s]: drain/contain mismatch r_hs=%0d rready_high=%0d ack=%0d",
               START_WRONG_ID ? "RID" : "RAR", r_hs_count, rready_high_count, ack_count);
      local_errs++;
    end
    if (buserr_low_count != 0 || bus_err !== 1'b1) begin
      $display("FAIL [%s]: bus_err not same-cycle/sticky low=%0d final=%b",
               START_WRONG_ID ? "RID" : "RAR", buserr_low_count, bus_err);
      local_errs++;
    end
    if (m_idle !== 1'b0) begin
      $display("FAIL [%s]: unowned R response incorrectly left master idle",
               START_WRONG_ID ? "RID" : "RAR");
      local_errs++;
    end
    // The terminal state must be recoverable only through the coupled reset
    // contract.  After reset a matching-ID read must complete normally again.
    @(negedge clk) fault_reset = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk) begin
      fault_id = 1'b0;
      fault_reset = 1'b0;
    end
    repeat (2) @(posedge clk);
    @(negedge clk) m_req = 1'b1;
    guard = 0;
    while (!m_ack && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    if (!m_ack || m_rdata !== 32'hBAD0_1D00) begin
      $display("FAIL [%s]: reset recovery read ack=%b data=%08x",
               START_WRONG_ID ? "RID" : "RAR", m_ack, m_rdata);
      local_errs++;
    end
    @(negedge clk) m_req = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (bus_err !== 1'b0 || m_idle !== 1'b1) begin
      $display("FAIL [%s]: reset recovery bus_err=%b m_idle=%b",
               START_WRONG_ID ? "RID" : "RAR", bus_err, m_idle);
      local_errs++;
    end
    errs = local_errs;
    if (local_errs == 0) begin
      if (START_WRONG_ID)
        $display("AXI-ID-CONTAIN-CASE-OK [RID] (wrong response drained, never delivered)");
      else
        $display("AXI-ID-CONTAIN-CASE-OK [RAR] (matching-ID pre-AR response contained)");
    end else if (START_WRONG_ID)
      $display("AXI-ID-CONTAIN-CASE-FAIL [RID] errs=%0d", local_errs);
    else
      $display("AXI-ID-CONTAIN-CASE-FAIL [RAR] errs=%0d", local_errs);
    done = 1'b1;
  end
endmodule

module axi_bid_contain_case (
    input logic clk,
    input logic rst_n,
    output logic done,
    output int   errs
);
  localparam int unsigned ADDR_W = 40;
  localparam logic [31:0] FIRST_ADDR  = 32'h0000_1200;
  localparam logic [31:0] SECOND_ADDR = 32'h0000_1204;
  logic fault_reset = 1'b0;
  logic fault_id = 1'b1;
  wire dut_rst_n = rst_n && !fault_reset;

  logic m_req, m_we, m_ack, bus_err, m_idle;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;

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
      .ADDR_W(ADDR_W), .WATCHDOG(64)
  ) dut (
      .core_clk(clk), .core_rst_n(dut_rst_n), .axi_clk(clk), .axi_rst_n(dut_rst_n),
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

  // Both write command channels are legal and independent.  Once the first
  // command has crossed, present an OKAY response with the wrong BID forever
  // unless a broken implementation accepts it.
  logic aw_seen, w_seen, b_pending, b_issued, second_req_live;
  wire aw_hs = awvalid && awready;
  wire w_hs  = wvalid && wready;
  wire write_complete = (aw_seen || aw_hs) && (w_seen || w_hs);
  assign awready = dut_rst_n;
  assign wready  = dut_rst_n;
  assign bid     = fault_id ? 4'hB : 4'd0;
  assign bresp   = 2'b00;
  assign bvalid  = b_pending;
  assign arready = dut_rst_n;
  assign rid     = 4'd0;
  assign rdata   = 32'd0;
  assign rresp   = 2'b00;
  assign rlast   = 1'b0;
  assign rvalid  = 1'b0;

  int aw_hs_count, w_hs_count, b_hs_count, bready_high_count;
  int first_ack_count, second_ack_count, buserr_low_count;
  logic fault_seen;
  always_ff @(posedge clk) begin
    if (!dut_rst_n) begin
      aw_seen           <= 1'b0;
      w_seen            <= 1'b0;
      b_pending         <= 1'b0;
      b_issued          <= 1'b0;
      aw_hs_count       <= 0;
      w_hs_count        <= 0;
      b_hs_count        <= 0;
      bready_high_count <= 0;
      first_ack_count   <= 0;
      second_ack_count  <= 0;
      buserr_low_count  <= 0;
      fault_seen        <= 1'b0;
    end else begin
      if (aw_hs) begin
        aw_seen     <= 1'b1;
        aw_hs_count <= aw_hs_count + 1;
      end
      if (w_hs) begin
        w_seen     <= 1'b1;
        w_hs_count <= w_hs_count + 1;
      end
      if (!b_pending && !b_issued && write_complete) begin
        b_pending <= 1'b1;
        b_issued  <= 1'b1;
      end
      if (bvalid && bready) begin
        b_pending  <= 1'b0;
        b_hs_count <= b_hs_count + 1;
      end
      if (!second_req_live && m_req && m_we && m_ack)
        first_ack_count <= first_ack_count + 1;
      if (second_req_live && m_ack)
        second_ack_count <= second_ack_count + 1;
      if (bvalid) begin
        fault_seen <= 1'b1;
        if (bready !== 1'b0) bready_high_count <= bready_high_count + 1;
        if (bus_err !== 1'b1) buserr_low_count <= buserr_low_count + 1;
      end
    end
  end

  initial begin : run_bid_case
    int guard;
    int local_errs;
    m_req = 1'b0;
    m_we = 1'b0;
    m_addr = 32'd0;
    m_wdata = 32'd0;
    m_wstrb = 4'd0;
    second_req_live = 1'b0;
    done = 1'b0;
    errs = 0;
    wait (dut_rst_n === 1'b1);
    repeat (2) @(posedge clk);

    @(negedge clk);
    m_req = 1'b1; m_we = 1'b1; m_addr = FIRST_ADDR;
    m_wdata = 32'h1111_2222; m_wstrb = 4'hF;
    guard = 0;
    while (first_ack_count == 0 && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    @(negedge clk);
    m_req = 1'b0; m_we = 1'b0; m_wstrb = 4'd0;

    guard = 0;
    while (!b_pending && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    // The first command has become an outstanding B.  Hold a second backing
    // store precisely while the wrong-ID B is visible to prove fatal_now blocks
    // same-edge admission, even though its response will not handshake.
    @(negedge clk);
    second_req_live = 1'b1;
    m_req = 1'b1; m_we = 1'b1; m_addr = SECOND_ADDR;
    m_wdata = 32'h3333_4444; m_wstrb = 4'hF;
    guard = 0;
    while (!fault_seen && guard < 20) begin
      @(posedge clk); #1;
      guard++;
    end
    @(negedge clk);
    m_req = 1'b0; m_we = 1'b0; m_wstrb = 4'd0; second_req_live = 1'b0;
    repeat (3) @(posedge clk);
    #1;

    local_errs = 0;
    if (!fault_seen) begin
      $display("FAIL [BID]: wrong-ID B response was never presented");
      local_errs++;
    end
    if (first_ack_count != 1) begin
      $display("FAIL [BID]: first posted-store admissions=%0d (exp 1)", first_ack_count);
      local_errs++;
    end
    if (second_ack_count != 0 || b_hs_count != 1 || bready_high_count != 1) begin
      $display("FAIL [BID]: drain/contain mismatch second_ack=%0d b_hs=%0d bready_high=%0d",
               second_ack_count, b_hs_count, bready_high_count);
      local_errs++;
    end
    if (aw_hs_count != 1 || w_hs_count != 1) begin
      $display("FAIL [BID]: follow-on write reached AXI aw=%0d w=%0d (exp 1/1)",
               aw_hs_count, w_hs_count);
      local_errs++;
    end
    if (buserr_low_count != 0 || bus_err !== 1'b1) begin
      $display("FAIL [BID]: bus_err not same-cycle/sticky low=%0d final=%b",
               buserr_low_count, bus_err);
      local_errs++;
    end
    if (m_idle !== 1'b0) begin
      $display("FAIL [BID]: foreign B incorrectly released write queue to idle");
      local_errs++;
    end
    // Coupled reset must discard the terminal bookkeeping state.  A fresh,
    // matching-ID posted store then proves no permanent deadlock/false error.
    @(negedge clk) fault_reset = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk) begin
      fault_id = 1'b0;
      fault_reset = 1'b0;
    end
    repeat (2) @(posedge clk);
    @(negedge clk);
    m_req = 1'b1; m_we = 1'b1; m_addr = FIRST_ADDR;
    m_wdata = 32'h5555_AAAA; m_wstrb = 4'hF;
    guard = 0;
    while (!m_ack && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    if (!m_ack) begin
      $display("FAIL [BID]: reset recovery store was not admitted");
      local_errs++;
    end
    @(negedge clk);
    m_req = 1'b0; m_we = 1'b0; m_wstrb = 4'd0;
    guard = 0;
    while (!m_idle && guard < 40) begin
      @(posedge clk); #1;
      guard++;
    end
    if (bus_err !== 1'b0 || m_idle !== 1'b1) begin
      $display("FAIL [BID]: reset recovery bus_err=%b m_idle=%b", bus_err, m_idle);
      local_errs++;
    end
    errs = local_errs;
    if (local_errs == 0)
      $display("AXI-ID-CONTAIN-CASE-OK [BID] (foreign completion drained, write slot preserved)");
    else
      $display("AXI-ID-CONTAIN-CASE-FAIL [BID] errs=%0d", local_errs);
    done = 1'b1;
  end
endmodule

module tb_axi_id_contain;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic rid_done, rar_done, bid_done;
  int rid_errs, rar_errs, bid_errs;
  always #5 clk = ~clk;

  axi_rid_contain_case #(.START_WRONG_ID(1'b1), .STALL_AR(1'b1)) rid_case (
      .clk(clk), .rst_n(rst_n), .done(rid_done), .errs(rid_errs)
  );
  axi_rid_contain_case #(.START_WRONG_ID(1'b0), .STALL_AR(1'b0)) rar_case (
      .clk(clk), .rst_n(rst_n), .done(rar_done), .errs(rar_errs)
  );
  axi_bid_contain_case bid_case (
      .clk(clk), .rst_n(rst_n), .done(bid_done), .errs(bid_errs)
  );

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
  end

  initial begin
    wait (rid_done && rar_done && bid_done);
    if (rid_errs == 0 && rar_errs == 0 && bid_errs == 0)
      $display("AXI-ID-CONTAIN-GATE-OK (foreign AXI responses are terminally contained)");
    else
      $display("AXI-ID-CONTAIN-GATE-FAIL rid_errs=%0d rar_errs=%0d bid_errs=%0d",
               rid_errs, rar_errs, bid_errs);
    $finish;
  end

  initial begin
    #100000;
    $display("AXI-ID-CONTAIN-GATE-FAIL (timeout)");
    $finish;
  end
endmodule
