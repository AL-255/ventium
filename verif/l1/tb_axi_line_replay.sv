// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Discriminating regression for the cache-line replay workaround in
// ven_axi_master.  The local AXI responder returns a complete but stale INCR8
// line on the first AR, then the correct line on the repeated, identical AR.
// The shipping configuration must discard all stale beats and deliver only the
// eight ordered good beats.  The VEN_SINGLE_FILL diagnostic is built as a
// mutation control by the runner and must leak exactly the stale line.
//
// This proves only the one-stale-complete-burst model; it does not establish
// the physical root cause or make two stale bursts safe.  It intentionally
// does not share the general AXI BFM, so changing this fault model cannot alter
// unrelated L1 regressions.
module tb_axi_line_replay #(
  parameter bit REPLAY = 1'b1,
  parameter bit STALE_FIRST = 1'b1
);
  localparam int ADDR_W = 40;
  localparam logic [39:0] REMAP_BASE = 40'h0_4000_0000;
  // This regression isolates the stale-line replay contract.  Keep its source
  // word at line offset zero so it remains an INCR8 shape control; WRAP8
  // critical-word ordering is covered end-to-end by tb_l1_axi.
  localparam logic [31:0] PHYS = 32'h0000_1020;
  localparam logic [39:0] AXI_LINE = REMAP_BASE + 40'h0000_1020;

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
  logic arvalid, arready;
  logic [3:0] rid = 4'd0; logic [31:0] rdata = 32'd0;
  logic [1:0] rresp = 2'b00; logic rlast = 1'b0;
  logic rvalid = 1'b0, rready;

  ven_axi_master #(
      .ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .LINE_REPLAY(REPLAY)
  ) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req(m_req), .m_we(1'b0), .m_addr(PHYS),
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

  function automatic logic [31:0] stale_word(input logic [3:0] beat);
    stale_word = 32'hA510_0000 | {28'd0, beat};
  endfunction

  function automatic logic [31:0] good_word(input logic [3:0] beat);
    good_word = 32'h5A20_1000 | {28'd0, beat};
  endfunction

  int ar_count, r_handshakes, rlast_count, ar_shape_bad;
  int ack_count, stale_ack_count, good_ack_count, bad_ack_count;
  logic stream_active, response_good;
  logic [3:0] response_beat;

  // Never accept a new AR while streaming the preceding response.  RVALID,
  // RDATA, and RLAST remain stable until the DUT accepts a beat.
  assign arready = !stream_active && !rvalid;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar_count       <= 0;
      r_handshakes   <= 0;
      rlast_count    <= 0;
      ar_shape_bad   <= 0;
      stream_active  <= 1'b0;
      response_good  <= 1'b0;
      response_beat  <= 4'd0;
      rvalid         <= 1'b0;
      rdata          <= 32'd0;
      rlast          <= 1'b0;
    end else begin
      if (arvalid && arready) begin
        ar_count      <= ar_count + 1;
        stream_active <= 1'b1;
        response_good <= !STALE_FIRST || (ar_count != 0);
        response_beat <= 4'd0;
        rdata         <= (STALE_FIRST && ar_count == 0) ? stale_word(4'd0) : good_word(4'd0);
        rlast         <= 1'b0;
        rvalid        <= 1'b1;
        if (araddr !== AXI_LINE || arlen !== 8'd7 || arsize !== 3'd2 ||
            arburst !== 2'b01) begin
          $display("FAIL: line AR shape addr=%010x len=%0d size=%0d burst=%0d",
                   araddr, arlen, arsize, arburst);
          ar_shape_bad <= ar_shape_bad + 1;
        end
      end else if (rvalid && rready) begin
        r_handshakes <= r_handshakes + 1;
        if (rlast) rlast_count <= rlast_count + 1;
        if (response_beat == 4'd7) begin
          rvalid        <= 1'b0;
          rlast         <= 1'b0;
          stream_active <= 1'b0;
          response_beat <= 4'd0;
        end else begin
          response_beat <= response_beat + 4'd1;
          rdata <= response_good ? good_word(response_beat + 4'd1) :
                                  stale_word(response_beat + 4'd1);
          rlast <= (response_beat == 4'd6);
        end
      end
    end
  end

  // Count delivered backing beats separately from raw AXI R handshakes.  Unique
  // words make a swapped, stale, or reordered beat visible to the scoreboard.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ack_count       <= 0;
      stale_ack_count <= 0;
      good_ack_count  <= 0;
      bad_ack_count   <= 0;
    end else if (m_ack) begin
      ack_count <= ack_count + 1;
      if (m_rdata === good_word(good_ack_count[3:0])) begin
        good_ack_count <= good_ack_count + 1;
      end else if (m_rdata === stale_word(stale_ack_count[3:0])) begin
        stale_ack_count <= stale_ack_count + 1;
        $display("AXI-LINE-REPLAY-STALE-LEAK beat=%0d data=%08x",
                 stale_ack_count, m_rdata);
      end else begin
        bad_ack_count <= bad_ack_count + 1;
        $display("FAIL: delivered beat=%0d unexpected data=%08x",
                 ack_count, m_rdata);
      end
    end
  end

  initial begin
    int errs;
    m_req = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk); m_req = 1'b1;

    for (int guard = 0; guard < 300; guard++) begin
      @(posedge clk); #1;
      if (ack_count == 8) break;
      if (guard == 299) $display("FAIL: no eight-beat backing response");
    end
    // Keep the backing request asserted through every delivered line beat;
    // release only after the final one, exactly as ven_l1d does for a fill.
    @(negedge clk); m_req = 1'b0;
    repeat (4) @(posedge clk); #1;

    errs = 0;
    if (ar_count != (REPLAY ? 2 : 1)) begin
      $display("FAIL: AR count got %0d exp %0d", ar_count, REPLAY ? 2 : 1); errs++;
    end
    if (r_handshakes != (REPLAY ? 16 : 8)) begin
      $display("FAIL: R handshakes got %0d exp %0d", r_handshakes, REPLAY ? 16 : 8); errs++;
    end
    if (rlast_count != (REPLAY ? 2 : 1)) begin
      $display("FAIL: RLAST count got %0d exp %0d", rlast_count, REPLAY ? 2 : 1); errs++;
    end
    if (ar_shape_bad != 0) begin
      $display("FAIL: malformed line AR count %0d", ar_shape_bad); errs++;
    end
    if (ack_count != 8 || stale_ack_count != 0 || good_ack_count != 8 ||
        bad_ack_count != 0) begin
      $display("FAIL: delivered acks=%0d stale=%0d good=%0d bad=%0d (exp 8/0/8/0)",
               ack_count, stale_ack_count, good_ack_count, bad_ack_count);
      errs++;
    end
    if (bus_err) begin $display("FAIL: bus_err asserted"); errs++; end
    if (!m_idle) begin $display("FAIL: master did not return idle"); errs++; end
    if (errs == 0)
      $display("AXI-LINE-REPLAY-GATE-OK ar=%0d r=%0d rlast=%0d stale_acks=%0d good_acks=%0d",
               ar_count, r_handshakes, rlast_count, stale_ack_count, good_ack_count);
    else
      $display("AXI-LINE-REPLAY-GATE-FAIL errs=%0d ar=%0d r=%0d rlast=%0d stale_acks=%0d good_acks=%0d",
               errs, ar_count, r_handshakes, rlast_count, stale_ack_count, good_ack_count);
    $finish;
  end
endmodule
