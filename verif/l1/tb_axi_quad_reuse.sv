// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// A reused P54 write-buffer slot must not retain its previous quad packet type.
// No guest/application addresses are used: fuse a pair, drain it, then reuse
// that slot as the younger member of a nonfused pair (including ..4 alignment).
module tb_axi_quad_reuse;
`ifdef VEN_AXI_QUAD_REUSE_ALIGNED_V
  localparam logic [31:0] V_ADDR = 32'h48;
`else
  localparam logic [31:0] V_ADDR = 32'h44;
`endif
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic m_req = 0, m_we = 1, m_pair_req = 0;
  logic [31:0] m_addr = 0, m_wdata = 0, m_pair_addr = 0, m_pair_wdata = 0, m_rdata;
  logic [3:0] m_wstrb = 4'hf, m_pair_wstrb = 4'hf;
  logic m_pair_ready, m_pair_ack, m_ack, bus_err, m_idle;
  logic [3:0] awid, arid;
  logic [39:0] awaddr, araddr;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize, awprot, arprot;
  logic [1:0] awburst, arburst;
  logic awlock, arlock;
  logic [3:0] awcache, arcache, awqos, arqos;
  logic awvalid, wvalid, wlast, bready, arvalid, rready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic awready, wready;
  logic bvalid = 0;
  int cycles = 0, aw_seen = 0, w_seen = 0, b_seen = 0, b_due = 0, b_delay = 0;
  int want_aw = 0, want_w = 0, want_b = 0;
  logic [31:0] expected_addr [0:5], expected_data [0:5];
  logic [7:0] expected_len [0:5];
  logic expected_last [0:5];
`ifdef VEN_AXI_QUAD_REUSE_BACKPRESSURE
  assign awready = (cycles % 3) == 0;
  assign wready = (cycles % 4) == 1;
`else
  assign awready = 1;
  assign wready = 1;
`endif
  ven_axi_master #(.ADDR_W(40), .WATCHDOG(256)) dut (
    .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
    .m_req, .m_we, .m_addr, .m_rd_narrow(1'b0), .m_rd_size(2'd2), .m_wdata, .m_wstrb,
    .m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,
    .m_pair_ready, .m_pair_ack, .m_rdata, .m_ack, .bus_err, .shutdown(1'b0), .m_idle,
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
    .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
    .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bid(4'd0), .m_axi_bresp(2'd0), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
    .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
    .m_axi_arvalid(arvalid), .m_axi_arready(1'b0),
    .m_axi_rid(4'd0), .m_axi_rdata(32'd0), .m_axi_rresp(2'd0),
    .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0), .m_axi_rready(rready)
  );
  // Print payload on the preceding half clock so an internal SVA fatal cannot
  // hide the erroneous command. This observes only, never repairs ownership.
  always @(negedge clk)
    if (rst_n && awvalid)
      $display("[QUAD-REUSE-AW] addr=%h len=%0d size=%0d burst=%b strb=%h data=%h last=%b",
               awaddr, awlen, awsize, awburst, wstrb, wdata, wlast);
  always @(posedge clk) begin
    if (rst_n) begin
      cycles <= cycles + 1;
      if (bus_err || arvalid) $fatal(1, "unexpected bus/read failure");
      if (awvalid && awready) begin
        if (aw_seen >= want_aw || awaddr != {8'd0, expected_addr[aw_seen]} ||
            awlen != expected_len[aw_seen] || awsize != 3'd2 || awburst != 2'b01)
          $fatal(1, "AXI-QUAD-REUSE: AW ownership mismatch n=%0d addr=%h len=%0d expected=%h/%0d",
                 aw_seen, awaddr, awlen, expected_addr[aw_seen], expected_len[aw_seen]);
        aw_seen <= aw_seen + 1;
      end
      if (wvalid && wready) begin
        if (w_seen >= want_w || wdata != expected_data[w_seen] ||
            wstrb != 4'hf || wlast != expected_last[w_seen])
          $fatal(1, "AXI-QUAD-REUSE: W ownership mismatch n=%0d data=%h last=%b", w_seen, wdata, wlast);
        w_seen <= w_seen + 1;
      end
      case ({wvalid && wready && wlast, bvalid && bready})
        2'b10: b_due <= b_due + 1;
        2'b01: b_due <= b_due - 1;
        default: ;
      endcase
      if (bvalid && bready) begin
        if (b_due == 0) $fatal(1, "orphan B response");
        b_seen <= b_seen + 1;
        bvalid <= 0;
        b_delay <= 5;
      end else if (b_due > 0 && !bvalid) begin
        if (b_delay > 0) b_delay <= b_delay - 1;
        else bvalid <= 1;
      end
    end
  end
  task automatic expect_aw(input logic [31:0] addr, input logic [7:0] len);
    expected_addr[want_aw] = addr; expected_len[want_aw] = len; want_aw++;
    want_b++;
  endtask
  task automatic expect_w(input logic [31:0] data, input logic last);
    expected_data[want_w] = data; expected_last[want_w] = last; want_w++;
  endtask
  task automatic drain;
    for (int n = 0; n < 160; n++) begin
      @(negedge clk);
      if (m_idle && dut.wq_count == 0) begin
        if (aw_seen != want_aw || w_seen != want_w || b_seen != want_b)
          $fatal(1, "early drain/accounting mismatch aw=%0d/%0d w=%0d/%0d b=%0d/%0d",
                 aw_seen, want_aw, w_seen, want_w, b_seen, want_b);
        return;
      end
    end
    $fatal(1, "drain timeout");
  endtask
  task automatic submit_pair(input logic [31:0] ua, input logic [31:0] va,
                             input logic [31:0] ud, input logic [31:0] vd);
    @(negedge clk);
    m_req = 1; m_pair_req = 1; m_addr = ua; m_pair_addr = va;
    m_wdata = ud; m_pair_wdata = vd;
    #1;
    if (!m_pair_ready || !m_pair_ack || !m_ack) $fatal(1, "empty queue rejected pair");
    @(negedge clk);
    m_req = 0; m_pair_req = 0;
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
`ifdef VEN_AXI_QUAD_REUSE_SLOT1
    // Rotate the two-entry ring once so the stale younger slot is slot one.
    expect_aw(32'h10, 0); expect_w(32'h1111_1111, 1);
    @(negedge clk); m_req = 1; m_addr = 32'h10; m_wdata = 32'h1111_1111;
    #1; if (!m_ack) $fatal(1, "seed store rejected");
    @(negedge clk); m_req = 0;
    drain();
`endif
`ifdef VEN_P54_WBUF_QUAD_COMBINE
    expect_aw(32'h20, 1);
    expect_w(32'haaaa_0000, 0); expect_w(32'haaaa_0001, 1);
`else
    expect_aw(32'h20, 0); expect_aw(32'h24, 0);
    expect_w(32'haaaa_0000, 1); expect_w(32'haaaa_0001, 1);
`endif
    submit_pair(32'h20, 32'h24, 32'haaaa_0000, 32'haaaa_0001);
    drain();
`ifdef VEN_P54_WBUF_QUAD_COMBINE
`ifdef VEN_AXI_QUAD_REUSE_SLOT1
    if (!dut.wq_fused[1] || dut.wq_wp != 0) $fatal(1, "slot-one poison precondition missing");
`else
    if (!dut.wq_fused[0] || dut.wq_wp != 1) $fatal(1, "slot-zero poison precondition missing");
`endif
`endif
    expect_aw(32'h30, 0); expect_aw(V_ADDR, 0);
    expect_w(32'hbbbb_0000, 1); expect_w(32'hbbbb_0001, 1);
    submit_pair(32'h30, V_ADDR, 32'hbbbb_0000, 32'hbbbb_0001);
    drain();
    $display("AXI-QUAD-REUSE-GATE-OK aw=%0d w=%0d b=%0d", aw_seen, w_seen, b_seen);
    $finish;
  end
endmodule
