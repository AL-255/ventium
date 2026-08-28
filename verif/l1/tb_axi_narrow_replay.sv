// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Focused regression for the KV260 DDR-only narrow-read replay mode.  The PS
// bridge is modeled returning a stale response to the first AR and the correct
// word to the repeated AR.  The backing requester must see exactly one ack,
// carrying only the second response.  Generic/device integrations retain the
// default NARROW_REPLAY_SAFE=0 behavior covered by tb_l1axi_narrow.sv.
module tb_axi_narrow_replay;
  localparam int ADDR_W = 40;
  localparam logic [39:0] REMAP_BASE = 40'h0_4000_0000;
  localparam logic [31:0] PHYS = 32'h0000_0020;
  localparam logic [39:0] AXI_ADDR = REMAP_BASE + 40'(PHYS);
  localparam logic [31:0] STALE = 32'h8126_0000;
  localparam logic [31:0] GOOD  = 32'hF000_024D;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic m_req = 1'b0;
  logic [31:0] m_rdata;
  logic m_ack, bus_err, m_idle;

  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0] awsize; logic [1:0] awburst; logic awlock;
  logic [3:0] awcache; logic [2:0] awprot; logic [3:0] awqos;
  logic awvalid; logic awready = 1'b0;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid;
  logic wready = 1'b0;
  logic [3:0] bid = 4'd0; logic [1:0] bresp = 2'b00;
  logic bvalid = 1'b0, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0] arsize; logic [1:0] arburst; logic arlock;
  logic [3:0] arcache; logic [2:0] arprot; logic [3:0] arqos;
  logic arvalid; logic arready = 1'b1;
  logic [3:0] rid = 4'd0; logic [31:0] rdata = 32'd0;
  logic [1:0] rresp = 2'b00; logic rlast = 1'b1;
  logic rvalid = 1'b0, rready;

  ven_axi_master #(
      .ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE),
      .NARROW_REPLAY_SAFE(1'b1)
  ) dut (
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

  int errs = 0;
  int ar_count = 0;
  int ack_count = 0;
  logic response_pending = 1'b0;
  logic [31:0] response_data = 32'd0;

  // One single-beat response per accepted AR.  The first is deliberately the
  // stale instruction word observed on silicon for the IVT read at physical 20h.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar_count <= 0;
      rvalid <= 1'b0;
      response_pending <= 1'b0;
      response_data <= 32'd0;
    end else begin
      if (arvalid && arready) begin
        ar_count <= ar_count + 1;
        response_pending <= 1'b1;
        response_data <= (ar_count == 0) ? STALE : GOOD;
        if (araddr !== AXI_ADDR) begin
          $display("FAIL: ARADDR got %010x exp %010x", araddr, AXI_ADDR);
          errs <= errs + 1;
        end
        if (arlen !== 8'd0 || arsize !== 3'd2) begin
          $display("FAIL: narrow shape ARLEN=%0d ARSIZE=%0d", arlen, arsize);
          errs <= errs + 1;
        end
      end
      if (response_pending && !rvalid) begin
        rdata <= response_data;
        rvalid <= 1'b1;
        response_pending <= 1'b0;
      end else if (rvalid && rready) begin
        rvalid <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) ack_count <= 0;
    else if (m_ack) begin
      ack_count <= ack_count + 1;
      if (ar_count < 2) begin
        $display("FAIL: stale priming response leaked as m_ack");
        errs <= errs + 1;
      end
      if (m_rdata !== GOOD) begin
        $display("FAIL: m_rdata got %08x exp %08x", m_rdata, GOOD);
        errs <= errs + 1;
      end
    end
  end

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk); m_req = 1'b1;

    for (int guard = 0; guard < 100; guard++) begin
      @(posedge clk); #1;
      if (m_ack) break;
      if (guard == 99) begin
        $display("FAIL: no backing ack");
        errs++;
      end
    end
    @(negedge clk); m_req = 1'b0;
    repeat (3) @(posedge clk); #1;

    if (ar_count != 2) begin
      $display("FAIL: AR count got %0d exp 2", ar_count);
      errs++;
    end
    if (ack_count != 1) begin
      $display("FAIL: backing ack count got %0d exp 1", ack_count);
      errs++;
    end
    if (bus_err) begin
      $display("FAIL: bus_err asserted");
      errs++;
    end
    if (errs == 0) $display("AXI-NARROW-REPLAY-GATE-OK");
    else           $display("AXI-NARROW-REPLAY-GATE-FAIL errs=%0d", errs);
    $finish;
  end
endmodule
