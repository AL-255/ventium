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
//   3. AW/W acceptance alone does NOT free a P5 slot; the third store waits for
//      the oldest B response, while the second slot may still drain; and
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
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic m_pair_req = 1'b0, m_pair_ready, m_pair_ack;
  logic [31:0] m_pair_addr = '0, m_pair_wdata = '0;
  logic [3:0] m_pair_wstrb = '0;
`endif

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

`ifdef VEN_P54_PAIR_ALIAS_TEST
  localparam logic [31:0] TEST_ADDR_MASK = 32'h0000_001f;
`else
  localparam logic [31:0] TEST_ADDR_MASK = 32'hffff_ffff;
`endif
  ven_axi_master #(.ADDR_W(ADDR_W), .ADDR_MASK(TEST_ADDR_MASK), .WATCHDOG(128)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req, .m_we, .m_addr, .m_rd_narrow, .m_rd_size, .m_wdata, .m_wstrb,
`ifdef VEN_P54_DUAL_STORE_PAIR
      .m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,
      .m_pair_ready, .m_pair_ack,
`endif
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
  logic second_aw_before_b = 1'b0;
  logic third_aw_before_b = 1'b0;
  logic third_admitted_on_head_b = 1'b0;
`ifdef VEN_P54_WBUF_PIPE_DISPATCH_TEST
  int cycle_q = 0, first_aw_cycle = -1, second_aw_cycle = -1;
`endif

  // This controlled slave can accept pipelined AXI writes.  The DUT always drives
  // AW and W from one active entry; accepting both together is legal AXI and makes
  // the test's B-delay behavior explicit rather than hiding it behind a serial BFM.
  assign awready = rst_n && !hold_aw;
  assign wready  = rst_n && !hold_aw;
  assign bvalid  = (b_pending != 3'd0) && (b_delay == 8'd0);
  assign bid     = 4'd0;
`ifdef VEN_AXI_READ_ON_FINAL_B_ERROR_TEST
  assign bresp = (b_seen == 3'd0) ? 2'b10 : 2'b00;
`elsif VEN_P54_PAIR_ERROR_TEST
  assign bresp   = (b_seen == 3'd0) ? 2'b10 : 2'b00;
`else
  assign bresp   = 2'b00;
`endif

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
      second_aw_before_b <= 1'b0; third_aw_before_b <= 1'b0;
      third_admitted_on_head_b <= 1'b0;
      for (int i = 0; i < 256; i++) mem[i] <= 32'd0;
    end else begin
`ifdef VEN_P54_WBUF_PIPE_DISPATCH_TEST
      cycle_q <= cycle_q + 1;
`endif
      if (arvalid && (b_seen != 3'd3)) ar_before_drain <= 1'b1;
      if (awvalid && awready && wvalid && wready) begin
`ifdef VEN_P54_WBUF_PIPE_DISPATCH_TEST
        if (aw_seen == 3'd0) first_aw_cycle <= cycle_q;
        if (aw_seen == 3'd1) second_aw_cycle <= cycle_q;
`endif
        // All writes in this regression are aligned dwords; if FIFO order is lost,
        // the addresses/data below make it immediately visible.
        if (awaddr[9:2] != 8'(aw_seen) + 8'd4) write_order_bad <= 1'b1;
        mem[awaddr[9:2]] <= wdata;
        aw_seen <= aw_seen + 3'd1;
        // This is the positive half of the fixed two-entry P54C contract: the
        // second retained store must be able to reach AXI before the first B.
        // Merely checking that a third write does *not* do so would let a
        // one-deep accidental serialization regression pass unnoticed.
        if ((aw_seen == 3'd1) && (b_seen == 3'd0)) second_aw_before_b <= 1'b1;
        if ((aw_seen >= 3'd2) && (b_seen == 3'd0)) third_aw_before_b <= 1'b1;
        if (b_pending == 3'd0) b_delay <= 8'd12;
        b_pending <= b_pending + 3'd1;
      end else if ((b_pending != 3'd0) && (b_delay != 8'd0)) begin
        b_delay <= b_delay - 8'd1;
      end
      if (bvalid && bready) begin
        // The third CPU request has been held since the queue became full.  A
        // retiring head B response frees precisely one architectural P5 slot,
        // so the request must be accepted on THIS edge rather than one cycle
        // later.  This catches a throughput bubble without increasing depth.
        if (m_req && m_we && (m_addr == 32'h0000_0018))
          third_admitted_on_head_b <= m_ack;
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

`ifdef VEN_AXI_READ_ON_FINAL_B_TEST
    $display("[read-on-B] final B response and a read request share one admission edge");
    send_write(32'h0000_0010, 32'h1111_1111);
    @(negedge clk) hold_aw <= 1'b0;
    begin
      int guard = 0;
      while (!(b_pending == 3'd1 && b_delay == 8'd0)) begin
        @(negedge clk);
        if (++guard > 80) begin fail("write did not reach held final B"); break; end
      end
    end
    // BVALID is now high, but no B handshake has occurred yet. A registered
    // ARVALID after the very next edge is legal: the last B retired on it.
    m_req <= 1'b1; m_we <= 1'b0; m_addr <= 32'h0000_0010;
    m_rd_narrow <= 1'b1; m_rd_size <= 2'd2;
    #1;
    if (arvalid || b_seen != 3'd0) fail("read started before the final B edge");
    @(posedge clk);
    #1;
`ifdef VEN_AXI_READ_ON_FINAL_B_ERROR_TEST
    if (b_seen != 3'd1 || arvalid || !bus_err)
      fail("bad final B launched a younger read or missed the fatal error");
    if (errors == 0) $display("AXIWBUF-READ-ON-B-ERROR-GATE-OK");
    else             $display("AXIWBUF-READ-ON-B-ERROR-GATE-FAIL (%0d errors)", errors);
    $finish;
`else
    if (b_seen != 3'd1 || !arvalid)
      fail("read AR did not start on final-B retirement edge");
    begin
      int guard = 0;
      while (!m_ack) begin
        @(negedge clk);
        if (++guard > 40) begin fail("read never completed after final B"); break; end
      end
    end
    if (m_rdata !== 32'h1111_1111) fail("read returned wrong posted-store data");
    @(negedge clk);
    m_req <= 1'b0; m_rd_narrow <= 1'b0;
    repeat (3) @(negedge clk);
    if (bus_err || !m_idle || aw_seen != 3'd1)
      fail("read-on-B changed AXI ownership or final drain");
    if (errors == 0) $display("AXIWBUF-READ-ON-B-GATE-OK");
    else             $display("AXIWBUF-READ-ON-B-GATE-FAIL (%0d errors)", errors);
    $finish;
`endif
`elsif VEN_AXI_READ_ON_FINAL_B_TWOSLOT_TEST
    $display("[read-on-B] first of two B responses cannot release the read");
    send_write(32'h0000_0010, 32'h1111_1111);
    send_write(32'h0000_0014, 32'h2222_2222);
    @(negedge clk) hold_aw <= 1'b0;
    begin
      int guard = 0;
      while (!(b_pending == 3'd2 && b_delay == 8'd0)) begin
        @(negedge clk);
        if (++guard > 80) begin fail("two writes did not reach held B responses"); break; end
      end
    end
    m_req <= 1'b1; m_we <= 1'b0; m_addr <= 32'h0000_0014;
    m_rd_narrow <= 1'b1; m_rd_size <= 2'd2;
    #1;
    if (arvalid || b_seen != 3'd0) fail("read started before either B edge");
    @(posedge clk);
    #1;
    if (b_seen != 3'd1 || arvalid)
      fail("first B released read while the second slot was occupied");
    @(posedge clk);
    #1;
    if (b_seen != 3'd2 || !arvalid)
      fail("read failed to start on the second, final B edge");
    begin
      int guard = 0;
      while (!m_ack) begin
        @(negedge clk);
        if (++guard > 40) begin fail("read never completed after both B responses"); break; end
      end
    end
    if (m_rdata !== 32'h2222_2222) fail("two-slot read returned wrong data");
    @(negedge clk);
    m_req <= 1'b0; m_rd_narrow <= 1'b0;
    repeat (3) @(negedge clk);
    if (bus_err || !m_idle || aw_seen != 3'd2)
      fail("two-slot read-on-B changed AXI ownership or final drain");
    if (errors == 0) $display("AXIWBUF-READ-ON-B-TWOSLOT-GATE-OK");
    else             $display("AXIWBUF-READ-ON-B-TWOSLOT-GATE-FAIL (%0d errors)", errors);
    $finish;
`elsif VEN_P54_PAIR_ERROR_TEST
    $display("[error] bad B after pair admission blocks all future pair admission");
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0010; m_wdata <= 32'h1111_1111; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0014;
    m_pair_wdata <= 32'h2222_2222; m_pair_wstrb <= 4'hf;
    #1;
    if (!m_pair_ready || !m_ack || !m_pair_ack) fail("initial pair not admitted");
    @(posedge clk);
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_pair_req <= 1'b0;
    hold_aw <= 1'b0;
    begin
      int guard;
      guard = 0;
      while (b_seen == 3'd0) begin
        @(posedge clk);
        if (++guard > 100) begin fail("first error response did not arrive"); break; end
      end
    end
    @(negedge clk);
    if (!bus_err) fail("bad B did not raise sticky bus error");
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0018; m_wdata <= 32'h3333_3333;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_001c;
    m_pair_wdata <= 32'h4444_4444;
    repeat (3) @(posedge clk);
    if (m_pair_ready || m_ack || m_pair_ack || aw_seen != 3'd2)
      fail("bad B allowed a younger pair to admit or launch");
    if (errors == 0) $display("AXIWBUF-PAIR-ERROR-GATE-OK");
    else             $display("AXIWBUF-PAIR-ERROR-GATE-FAIL (%0d errors)", errors);
    $finish;
`elsif VEN_P54_PAIR_ALIAS_TEST
    $display("[alias] pair V address outside remap window rejects the whole pair");
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0010; m_wdata <= 32'h1111_1111; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0020;
    m_pair_wdata <= 32'h2222_2222; m_pair_wstrb <= 4'hf;
    #1;
    if (m_ack || m_pair_ack || dut.wq_count != 0)
      fail("out-of-window V store admitted either pair member");
    @(posedge clk);
    #1;
    if (!bus_err || dut.wq_count != 0 || aw_seen != 0)
      fail("out-of-window V store did not raise sticky alias fault");
    @(negedge clk);
    shutdown <= 1'b1;
    #1;
    if (m_ack || m_pair_ack)
      fail("shutdown acknowledged a pair after a fatal alias fault");

    $display("[alias] V straddle beyond remap window rejects the whole pair");
    @(negedge clk);
    rst_n <= 1'b0; shutdown <= 1'b0; m_req <= 1'b0; m_pair_req <= 1'b0;
    repeat (3) @(negedge clk);
    rst_n <= 1'b1;
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0010; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_001f; m_pair_wstrb <= 4'hf;
    #1;
    if (m_ack || m_pair_ack || dut.wq_count != 0)
      fail("V store crossing remap-window end admitted either pair member");
    @(posedge clk);
    #1;
    if (!bus_err || dut.wq_count != 0 || aw_seen != 0)
      fail("V store crossing remap-window end did not raise sticky alias fault");

    if (errors == 0) $display("AXIWBUF-PAIR-ALIAS-GATE-OK");
    else             $display("AXIWBUF-PAIR-ALIAS-GATE-FAIL (%0d errors)", errors);
    $finish;
`else
    $display("[1] P54C capacity: two stores admitted while AXI AW/W is blocked");
    send_write(32'h0000_0010, 32'h1111_1111);
    // Let the first saved entry become active, then occupy the second P54C slot.
    repeat (2) @(posedge clk);
    send_write(32'h0000_0014, 32'h2222_2222);
    start_blocked_write(32'h0000_0018, 32'h3333_3333);
    repeat (5) @(posedge clk);
    if (m_ack) fail("third store bypassed the fixed two-entry P54C buffer");
    else $display("  ok   third store held while both P54C entries occupied");

    $display("[2] release AXI: FIFO order; B, not AW/W, frees the P54C slot");
    @(negedge clk) hold_aw <= 1'b0;
    finish_write;

    $display("[3] a following read waits for every delayed B response");
    do_narrow_read(32'h0000_0018, 32'h3333_3333);
    if (ar_before_drain) fail("AR issued before all earlier write responses drained");
    else $display("  ok   read AR stayed behind all queued writes");
    if (!second_aw_before_b) fail("second AXI write did not launch before first P54C B");
    if (third_aw_before_b) fail("third AXI write launched before any P54C slot received B");
    if (!third_admitted_on_head_b) fail("third CPU write was not admitted on the head B handshake");
    if (write_order_bad || aw_seen != 3'd3) fail("AXI write FIFO order/count was wrong");
    else $display("  ok   AXI write order preserved (3 stores)");
    if (!m_idle) fail("master not idle after read/write drain");
    if (bus_err) fail("unexpected AXI bus error");
`ifdef VEN_P54_WBUF_PIPE_DISPATCH_TEST
    if (second_aw_cycle != first_aw_cycle + 1)
      fail($sformatf("queued second AW/W had issue bubble: %0d -> %0d",
                     first_aw_cycle, second_aw_cycle));
    if (errors == 0) $display("AXIWBUF-PIPE-DISPATCH-GATE-OK");
    else             $display("AXIWBUF-PIPE-DISPATCH-GATE-FAIL (%0d errors)", errors);
`endif

`ifdef VEN_P54_DUAL_STORE_PAIR
    $display("[4] pair consumes exactly two slots atomically in U/V order");
    @(negedge clk);
    rst_n <= 1'b0;
    hold_aw <= 1'b1;
    repeat (3) @(negedge clk);
    rst_n <= 1'b1;
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0010; m_wdata <= 32'h1111_1111; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0014;
    m_pair_wdata <= 32'h2222_2222;
    m_pair_wstrb <= 4'hf;
    #1;
    if (!m_pair_ready || !m_ack || !m_pair_ack)
      fail("empty two-slot pair was not admitted atomically");
    @(posedge clk);
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_pair_req <= 1'b0;
    if (dut.wq_count != 2 || dut.wq_addr[dut.wq_rp] != 32'h10 ||
        dut.wq_addr[~dut.wq_rp] != 32'h14)
      fail("pair did not occupy exactly two ordered slots");
    start_blocked_write(32'h0000_0018, 32'h3333_3333);
    repeat (4) @(posedge clk);
    if (m_ack) fail("third write admitted while atomic pair held both slots");
    @(negedge clk) hold_aw <= 1'b0;
    finish_write;
    do_narrow_read(32'h0000_0018, 32'h3333_3333);
    if (write_order_bad || aw_seen != 3'd3 || b_seen != 3'd3 ||
        mem[4] != 32'h1111_1111 || mem[5] != 32'h2222_2222 ||
        mem[6] != 32'h3333_3333 || ar_before_drain || bus_err)
      fail("atomic pair changed AXI order, data, read barrier, or error state");

    $display("[5] one free slot rejects the whole pair until head B retires");
    @(negedge clk);
    rst_n <= 1'b0;
    hold_aw <= 1'b1;
    repeat (3) @(negedge clk);
    rst_n <= 1'b1;
    send_write(32'h0000_0010, 32'h1111_1111);
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0014; m_wdata <= 32'h2222_2222; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0018;
    m_pair_wdata <= 32'h3333_3333;
    m_pair_wstrb <= 4'hf;
    repeat (4) @(posedge clk);
    if (m_pair_ready || m_ack || m_pair_ack || dut.wq_count != 1)
      fail("single free slot accepted one or both members of a pair");
    @(negedge clk) hold_aw <= 1'b0;
    begin
      int guard;
      guard = 0;
      while (!m_pair_ack) begin
        @(posedge clk);
        if (++guard > 80) begin fail("pair not admitted on released head B"); break; end
      end
      if (m_pair_ack && (!m_pair_ready || !m_ack))
        fail("younger store acked without older store or two-slot credit");
    end
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_pair_req <= 1'b0;
    do_narrow_read(32'h0000_0018, 32'h3333_3333);
    if (write_order_bad || aw_seen != 3'd3 || b_seen != 3'd3 ||
        mem[4] != 32'h1111_1111 || mem[5] != 32'h2222_2222 ||
        mem[6] != 32'h3333_3333 || ar_before_drain || bus_err)
      fail("released-head pair violated order, capacity, data or read drain");

    $display("[6] full pair needs both B releases; shutdown acks both locally");
    @(negedge clk);
    rst_n <= 1'b0;
    hold_aw <= 1'b1;
    repeat (3) @(negedge clk);
    rst_n <= 1'b1;
    @(negedge clk);
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0010; m_wdata <= 32'h1111_1111; m_wstrb <= 4'hf;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0014;
    m_pair_wdata <= 32'h2222_2222;
    m_pair_wstrb <= 4'hf;
    @(posedge clk);
    @(negedge clk);
    m_addr <= 32'h0000_0018; m_wdata <= 32'h3333_3333;
    m_pair_addr <= 32'h0000_001c;
    m_pair_wdata <= 32'h4444_4444;
    repeat (4) @(posedge clk);
    if (m_pair_ready || m_ack || m_pair_ack || dut.wq_count != 2)
      fail("full two-slot queue accepted another pair");
    @(negedge clk) hold_aw <= 1'b0;
    begin
      int guard;
      guard = 0;
      while (!m_pair_ack) begin
        @(posedge clk);
        if (bvalid && bready && b_seen == 3'd0 && (m_ack || m_pair_ack))
          fail("pair admitted when only first B response freed one slot");
        if (++guard > 100) begin fail("second pair never admitted after both B responses"); break; end
      end
      if (m_pair_ack && !m_ack) fail("second pair was not atomic");
    end
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_pair_req <= 1'b0;
    begin
      int guard;
      guard = 0;
      while (!m_idle) begin
        @(posedge clk);
        if (++guard > 100) begin fail("four-store pair sequence never drained"); break; end
      end
    end
    if (write_order_bad || aw_seen != 3'd4 || b_seen != 3'd4 ||
        mem[4] != 32'h1111_1111 || mem[5] != 32'h2222_2222 ||
        mem[6] != 32'h3333_3333 || mem[7] != 32'h4444_4444 || bus_err)
      fail("two-pair sequence lost AXI order, data or completion");
    @(negedge clk);
    shutdown <= 1'b1;
    m_req <= 1'b1; m_we <= 1'b1;
    m_addr <= 32'h0000_0020; m_wdata <= 32'h5555_5555;
    m_pair_req <= 1'b1;
    m_pair_addr <= 32'h0000_0024; m_pair_wdata <= 32'h6666_6666;
    #1;
    if (!m_ack || !m_pair_ack || !m_idle || dut.wq_count != 0)
      fail("shutdown did not locally ack both pair members without enqueue");
    @(negedge clk);
    m_req <= 1'b0; m_we <= 1'b0; m_pair_req <= 1'b0; shutdown <= 1'b0;
`endif

    if (errors == 0) $display("AXIWBUF-GATE-OK (P54C two-buffer capacity + FIFO + read drain)");
    else             $display("AXIWBUF-GATE-FAIL (%0d errors)", errors);
    $finish;
`endif
  end

  initial begin
    #100000;
    $display("AXIWBUF-GATE-FAIL (timeout)");
    $finish;
  end
endmodule
