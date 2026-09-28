// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Focused P54 write-buffer quadword-combine / AXI burst microbenchmark.
module tb_axi_quad_pair;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic m_req = 0, m_we = 0, m_rd_narrow = 0;
  logic [31:0] m_addr = 0, m_wdata = 0, m_pair_addr = 0, m_pair_wdata = 0, m_rdata;
  logic [3:0] m_wstrb = 0, m_pair_wstrb = 0;
  logic [1:0] m_rd_size = 2;
  logic m_pair_req = 0, m_pair_ready, m_pair_ack, m_ack, bus_err, m_idle;
  logic [3:0] awid, bid, arid, rid;
  logic [39:0] awaddr, araddr;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst;
  logic awlock, arlock;
  logic [3:0] awcache, arcache, awqos, arqos;
  logic [2:0] awprot, arprot;
  logic awvalid, wvalid, wlast, bready, arvalid, rready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic bvalid = 0, rvalid = 0, rlast = 0;
  logic [31:0] rdata = 0;
  logic [1:0] bresp, rresp = 0;
`ifdef VEN_AXI_QUAD_BRESP_ERROR
  assign bresp = (b_seen == 1) ? 2'b10 : 2'b00;
`else
  assign bresp = 2'b00;
`endif
  ven_axi_master #(.ADDR_W(40), .WATCHDOG(256)) dut (
    .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
    .m_req, .m_we, .m_addr, .m_rd_narrow, .m_rd_size, .m_wdata, .m_wstrb,
    .m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,
    .m_pair_ready, .m_pair_ack, .m_rdata, .m_ack, .bus_err, .shutdown(1'b0), .m_idle,
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
    .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
    .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
    .m_axi_awvalid(awvalid), .m_axi_awready(1'b1),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(1'b1),
    .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
    .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
    .m_axi_arvalid(arvalid), .m_axi_arready(1'b1),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
    .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );
  assign bid = 0;
  assign rid = 0;
  int aw_seen = 0, w_seen = 0, b_seen = 0, b_due = 0, delay_ctr = 0, ar_seen = 0;
  logic [31:0] mem [0:15];
  always @(posedge clk) begin
    if (rst_n) begin
      if (awvalid) begin
        case (aw_seen)
          0: if (awaddr != 40'h10 || awlen != 0) $fatal(1, "first AW shape");
          1: if (awaddr != 40'h20 || awlen != 1 || awburst != 2'b01)
               $fatal(1, "fused AW shape");
          default: $fatal(1, "unexpected AW");
        endcase
        aw_seen <= aw_seen + 1;
      end
      if (wvalid) begin
        case (w_seen)
          0: if (wdata != 32'h1111_1111 || wstrb != 4'hf || !wlast)
               $fatal(1, "first W");
          1: if (wdata != 32'h2222_2222 || wstrb != 4'hf || wlast)
               $fatal(1, "fused W0");
          2: if (wdata != 32'h3333_3333 || wstrb != 4'hf || !wlast)
               $fatal(1, "fused W1");
          default: $fatal(1, "unexpected W");
        endcase
        if (w_seen == 0) mem[4] <= wdata;
        if (w_seen == 1) mem[8] <= wdata;
        if (w_seen == 2) mem[9] <= wdata;
        w_seen <= w_seen + 1;
      end
      case ({wvalid && wlast, bvalid && bready})
        2'b10: b_due <= b_due + 1;
        2'b01: b_due <= b_due - 1;
        default: ;
      endcase
      if (bvalid && bready) begin
        if (b_due == 0) $fatal(1, "orphan B");
        b_seen <= b_seen + 1;
        bvalid <= 0;
        delay_ctr <= 6;
      end else if (b_due > 0 && !bvalid) begin
        if (delay_ctr > 0) delay_ctr <= delay_ctr - 1;
        else bvalid <= 1;
      end
      if (arvalid) begin
`ifdef VEN_AXI_QUAD_BRESP_ERROR
        $fatal(1, "errored pair let read pass");
`endif
        if (b_seen != 2 || aw_seen != 2 || w_seen != 3)
          $fatal(1, "read passed posted writes");
        if (araddr != 40'h20 || arlen != 0) $fatal(1, "read shape");
        ar_seen <= ar_seen + 1;
        rdata <= mem[8]; rvalid <= 1; rlast <= 1;
      end else if (rvalid && rready) begin
        rvalid <= 0; rlast <= 0;
      end
    end
  end
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    m_req = 1; m_we = 1; m_addr = 32'h10; m_wdata = 32'h1111_1111; m_wstrb = 4'hf;
    #1;
    if (!m_ack) $fatal(1, "first store not admitted");
    @(negedge clk);
    m_req = 0;
    @(negedge clk);
    m_req = 1; m_pair_req = 1;
`ifdef VEN_AXI_QUAD_SPLIT_TEST
    m_addr = 32'h14; m_pair_addr = 32'h18;
`else
    m_addr = 32'h20; m_pair_addr = 32'h24;
`endif
    m_wdata = 32'h2222_2222; m_pair_wdata = 32'h3333_3333;
    m_wstrb = 4'hf; m_pair_wstrb = 4'hf;
    #1;
`ifdef VEN_AXI_QUAD_SPLIT_TEST
    if (m_pair_ready || m_pair_ack || m_ack || dut.wq_count != 1)
      $fatal(1, "non-quad pair consumed one free buffer");
    $display("AXI-QUAD-SPLIT-GATE-OK");
    $finish;
`endif
    if (!m_pair_ready || !m_pair_ack || !m_ack)
      $fatal(1, "fused pair must fit free quadword buffer");
    @(negedge clk);
    m_req = 0; m_pair_req = 0; m_we = 0;
    @(negedge clk);
    m_req = 1; m_addr = 32'h20; m_rd_narrow = 1; m_rd_size = 2;
    for (int i = 0; i < 150; i++) begin
      @(negedge clk);
`ifdef VEN_AXI_QUAD_BRESP_ERROR
      if (b_seen == 2) begin
        if (!bus_err || m_ack || ar_seen != 0)
          $fatal(1, "errored fused B lost its terminal containment");
        $display("AXI-QUAD-PAIR-ERROR-GATE-OK aw=%0d w=%0d b=%0d", aw_seen, w_seen, b_seen);
        $finish;
      end
`else
      if (m_ack) begin
        if (m_rdata != 32'h2222_2222 || bus_err || ar_seen != 1 || b_seen != 2)
          $fatal(1, "read/final accounting mismatch");
        $display("AXI-QUAD-PAIR-GATE-OK aw=%0d w=%0d b=%0d", aw_seen, w_seen, b_seen);
        $finish;
      end
`endif
    end
    $fatal(1, "timeout");
  end
endmodule
