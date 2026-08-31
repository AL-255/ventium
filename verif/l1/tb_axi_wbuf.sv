// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// tb_axi_wbuf.sv — directed P54C two-write-buffer / AXI ordering regression.
//
// The normal AXI BFM deliberately permits only one write response at a time, which
// is ideal for basic protocol coverage but cannot prove that the master can retain
// two P54C writes while the target has not yet replied.  This focused slave accepts
// AW/W independently, delays B, and emits ordered B responses.  It proves:
//   1. exactly two CPU memory stores can be admitted while AW/W is blocked;
//   2. a third store stalls (no unbounded "performance" queue);
//   3. writes reach AXI in FIFO order once released; and
//   4. a following narrow read cannot present AR until every earlier B completed.
//
// This is deliberately a generic memory test: no VGA/Quake address or behavior is
// encoded here.  It is the P54C §2.6 ordering contract at the AXI seam.

module tb_axi_wbuf;
  localparam int ADDR_W = 40;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // backing-side request into ven_axi_master
  logic        m_req = 1'b0, m_we = 1'b0, m_rd_narrow = 1'b0;
  logic [31:0] m_addr = '0, m_wdata = '0, m_rdata;
  logic [3:0]  m_wstrb = '0;
  logic [1:0]  m_rd_size = 2'd2;
  logic        m_ack, bus_err, shutdown = 1'b0, m_idle;

  // AXI wires
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

  ven_axi_master #(.ADDR_W(ADDR_W), .WATCHDOG(128)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req, .m_we, .m_addr, .m_rd_narrow, .m_rd_size, .m_wdata, .m_wstrb,
      .m_rdata, .m_ack, .bus_err, .shutdown, .m_idle,
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
      .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
      .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arcache(arcache),
      .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
      .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  int errors = 0;
  logic hold_aw = 1'b1;
  logic [31:0] mem [0:255];
  logic [2:0] b_pending = '0, b_seen = '0, aw_seen = '0;
  logic [7:0] b_delay = '0;
  logic r_pending = 1'b0;
  logic [31:0] r_addr_q = '0;
  logic ar_before_drain = 1'b0;
  logic write_order_bad = 1'b0;

  // This controlled slave can accept pipelined AXI writes.  The DUT always drives
  // AW and W from one active entry; accepting both together is legal AXI and makes
  // the test's B-delay behavior explicit rather than hiding it behind a serial BFM.
  assign awready = rst_n && !hold_aw;
  assign wready  = rst_n && !hold_aw;
  assign bvalid  = (b_pending != 3'd0) && (b_delay == 8'd0);
  assign bid     = 4'd0;
  assign bresp   = 2'b00;

  // A single narrow read response is sufficient to prove the read barrier.
  assign arready = rst_n && !r_pending;
  assign rvalid  = r_pending;
  assign rdata   = mem[r_addr_q[9:2]];
  assign rid     = 4'd0;
  assign rresp   = 2'b00;
  assign rlast   = 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      b_pending <= '0; b_seen <= '0; aw_seen <= '0; b_delay <= '0;
      r_pending <= 1'b0; r_addr_q <= '0;
      ar_before_drain <= 1'b0; write_order_bad <= 1'b0;
      for (int i = 0; i < 256; i++) mem[i] <= 32'd0;
    end else begin
      if (arvalid && (b_seen != 3'd3)) ar_before_drain <= 1'b1;
      if (awvalid && awready && wvalid && wready) begin
        // All writes in this regression are aligned dwords; if FIFO order is lost,
        // the addresses/data below make it immediately visible.
        if (awaddr[9:2] != 8'(aw_seen) + 8'd4) write_order_bad <= 1'b1;
        mem[awaddr[9:2]] <= wdata;
        aw_seen <= aw_seen + 3'd1;
        if (b_pending == 3'd0) b_delay <= 8'd12;
        b_pending <= b_pending + 3'd1;
      end else if ((b_pending != 3'd0) && (b_delay != 8'd0)) begin
        b_delay <= b_delay - 8'd1;
      end
      if (bvalid && bready) begin
        b_pending <= b_pending - 3'd1;
        b_seen <= b_seen + 3'd1;
      end
      if (arvalid && arready) begin
        r_pending <= 1'b1;
        r_addr_q <= araddr[31:0];
      end else if (rvalid && rready) begin
        r_pending <= 1'b0;
      end
    end
  end

  task automatic fail(input string why);
    $display("  FAIL %s", why);
    errors++;
  endtask

  task automatic send_write(input logic [31:0] a, input logic [31:0] d);
    int guard;
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1; m_addr <= a; m_wdata <= d; m_wstrb <= 4'hF;
    guard = 0;
    while (!m_ack) begin
      @(posedge clk);
      if (++guard > 80) begin fail($sformatf("write %08x was not admitted", a)); break; end
    end
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_wstrb <= '0;
  endtask

  task automatic start_blocked_write(input logic [31:0] a, input logic [31:0] d);
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1; m_addr <= a; m_wdata <= d; m_wstrb <= 4'hF;
  endtask

  task automatic finish_write;
    int guard;
    guard = 0;
    while (!m_ack) begin
      @(posedge clk);
      if (++guard > 120) begin fail("third write never admitted after a buffer freed"); break; end
    end
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_wstrb <= '0;
  endtask

  task automatic do_narrow_read(input logic [31:0] a, input logic [31:0] expected);
    int guard;
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b0; m_addr <= a; m_rd_narrow <= 1'b1; m_rd_size <= 2'd2;
    guard = 0;
    while (!m_ack) begin
      @(posedge clk);
      if (++guard > 200) begin fail("read did not complete"); break; end
    end
    if (m_rdata !== expected) fail($sformatf("read got %08x expected %08x", m_rdata, expected));
    @(negedge clk);
    m_req <= 1'b0; m_rd_narrow <= 1'b0;
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    $display("[1] P54C capacity: two stores admitted while AXI AW/W is blocked");
    send_write(32'h0000_0010, 32'h1111_1111);
    // Let the first saved entry become active, then occupy the second P54C slot.
    repeat (2) @(posedge clk);
    send_write(32'h0000_0014, 32'h2222_2222);
    start_blocked_write(32'h0000_0018, 32'h3333_3333);
    repeat (5) @(posedge clk);
    if (m_ack) fail("third store bypassed the fixed two-entry P54C buffer");
    else $display("  ok   third store held while both P54C entries occupied");

    $display("[2] release AXI: FIFO write order and bounded third admission");
    @(negedge clk) hold_aw <= 1'b0;
    finish_write;

    $display("[3] a following read waits for every delayed B response");
    do_narrow_read(32'h0000_0018, 32'h3333_3333);
    if (ar_before_drain) fail("AR issued before all earlier write responses drained");
    else $display("  ok   read AR stayed behind all queued writes");
    if (write_order_bad || aw_seen != 3'd3) fail("AXI write FIFO order/count was wrong");
    else $display("  ok   AXI write order preserved (3 stores)");
    if (!m_idle) fail("master not idle after read/write drain");
    if (bus_err) fail("unexpected AXI bus error");

    if (errors == 0) $display("AXIWBUF-GATE-OK (P54C two-buffer capacity + FIFO + read drain)");
    else             $display("AXIWBUF-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("AXIWBUF-GATE-FAIL (timeout)");
    $finish;
  end
endmodule
