// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Direct ven_axi_master RRESP containment regression.
//
// AXI RRESP is sampled on the same edge that would otherwise deliver RDATA to
// ven_l1d.  A registered-only error indication is one clock too late: a bad
// line word can already have entered an L1 fill (or a narrow bypass) before
// bus_err becomes visible.  This deliberately non-OKAY responder proves the
// required boundary behavior without changing the shared AXI BFM:
//
//   * cacheable fill: AR #0 is an entirely correct priming WRAP8 burst; AR #1
//     has SLVERR at delivered beat 3 while RLAST remains protocol-correct.
//     Beats 0..2 of AR #1 must be acked, but the faulting and all following
//     beats must never be acked.  The failed priming/delivery must not issue a
//     third AR, and the R channel must still drain to IDLE.
//   * priming fill: AR #0 itself has SLVERR at beat 3.  It must remain entirely
//     invisible, drain cleanly, and crucially must NOT launch the normally
//     mandatory replay AR #1 after the error becomes sticky.
//   * final priming fill: the same fault on AR #0 beat 7.  This is the exact
//     final-beat race: the sequential rresp_err flag is not sticky until after
//     the edge on which the priming FSM would otherwise launch replay AR #1.
//   * narrow read: its sole, normally delivered beat is SLVERR.  It similarly
//     must not be acked, validates the same boundary for bypass/MMIO-shaped
//     traffic, and must return idle without replaying the access.
//   * replay-safe narrow priming: with NARROW_REPLAY_SAFE=1, that sole narrow
//     beat is instead the discarded priming response.  A bad priming beat must
//     not launch the normally required replay AR #1; this is the deployed
//     KV260 configuration's single-beat version of the final-priming race.
//
// The scoreboards sample in the active region of the clock edge, before the
// master's sequential sticky flags update.  Thus `fault_buserr_low` verifies
// the important same-handshake property rather than the weaker next-cycle one.
// The runner keeps assertions enabled and defines VEN_AXI_RESP_FAULT_INJECT,
// which suppresses only the deliberate response-status assumptions for this
// fault stimulus.

module axi_rresp_contain_case #(
    parameter bit    NARROW        = 1'b0,
    parameter bit    FAULT_PRIMING = 1'b0,
    parameter bit    REPLAY_SAFE   = 1'b0,
    parameter int unsigned FAULT_BEAT = NARROW ? 0 : 3,
    parameter string TAG           = "line"
) (
    input  logic clk,
    input  logic rst_n,
    output logic done,
    output int   errs
);
  localparam int unsigned ADDR_W = 40;
  localparam logic [39:0] REMAP_BASE = 40'h0_4000_0000;
  localparam logic [31:0] PHYS       = 32'h0000_1024;
  localparam int unsigned BEATS      = NARROW ? 1 : 8;
  localparam int unsigned FAULT_AR   = NARROW ? 0 : (FAULT_PRIMING ? 0 : 1);
  localparam int unsigned EXPECT_ARS = NARROW ? 1 : (FAULT_PRIMING ? 1 : 2);
  localparam int unsigned EXPECT_RHS = EXPECT_ARS * BEATS;
  localparam int unsigned EXPECT_PRE_ACK = (!NARROW && !FAULT_PRIMING) ? FAULT_BEAT : 0;
  localparam logic [3:0] LAST_BEAT = 4'(BEATS - 1);
  localparam logic [7:0] FAULT_AR_U8 = 8'(FAULT_AR);
  localparam logic [3:0] FAULT_BEAT_U4 = 4'(FAULT_BEAT);
  // A nonzero critical-word offset starts both cache-line bursts at PHYS;
  // WRAP8, not an aligned INCR8, enumerates the line from that first word.
  localparam logic [ADDR_W-1:0] AXI_ADDR = REMAP_BASE + ADDR_W'(PHYS);
  localparam logic [1:0] EXPECT_BURST = NARROW ? 2'b01 : 2'b10;

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
  logic [3:0] rid = 4'd0; logic [31:0] rdata;
  logic [1:0] rresp; logic rlast, rvalid, rready;

  ven_axi_master #(
      .ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE),
      .NARROW_REPLAY_SAFE(REPLAY_SAFE)
  ) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .m_req(m_req), .m_we(1'b0), .m_addr(PHYS),
      .m_rd_narrow(NARROW), .m_rd_size(2'd2),
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

  // A minimal registered responder.  It never starts a later AR until the
  // current response has been accepted in full, so an unexpected replay is
  // counted as a distinct third AR rather than hidden behind interleaving.
  logic stream_active;
  logic [7:0] stream_ar;
  logic [3:0] stream_beat;
  int ar_count, r_handshakes, rlast_count, ar_shape_bad, rlast_shape_bad;

  function automatic logic [31:0] response_word(
      input logic [7:0] ar_n, input logic [3:0] beat_n);
    response_word = 32'hA500_0000 | {20'd0, ar_n, beat_n};
  endfunction

  assign arready = !stream_active;
  always_comb begin
    rvalid = stream_active;
    rdata  = response_word(stream_ar, stream_beat);
    rresp  = 2'b00;
    rlast  = stream_active && (stream_beat == LAST_BEAT);
    if (stream_active && (stream_ar == FAULT_AR_U8) &&
        (stream_beat == FAULT_BEAT_U4))
      rresp = 2'b10;  // SLVERR -- deliberate fault, not a malformed R burst.
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stream_active  <= 1'b0;
      stream_ar      <= 8'd0;
      stream_beat    <= 4'd0;
      ar_count       <= 0;
      r_handshakes   <= 0;
      rlast_count    <= 0;
      ar_shape_bad   <= 0;
      rlast_shape_bad <= 0;
    end else begin
      if (arvalid && arready) begin
        ar_count      <= ar_count + 1;
        stream_active <= 1'b1;
        stream_ar     <= ar_count[7:0];
        stream_beat   <= 4'd0;
        if (araddr !== AXI_ADDR || arlen !== 8'(BEATS - 1) ||
            arsize !== 3'd2 || arburst !== EXPECT_BURST) begin
          $display("FAIL [%s]: AR shape addr=%010x len=%0d size=%0d burst=%0d",
                   TAG, araddr, arlen, arsize, arburst);
          ar_shape_bad <= ar_shape_bad + 1;
        end
      end
      if (rvalid && rready) begin
        r_handshakes <= r_handshakes + 1;
        if (rlast) rlast_count <= rlast_count + 1;
        if (rlast !== (stream_beat == LAST_BEAT))
          rlast_shape_bad <= rlast_shape_bad + 1;
        if (stream_beat == LAST_BEAT) begin
          stream_active <= 1'b0;
          stream_beat   <= 4'd0;
        end else begin
          stream_beat <= stream_beat + 4'd1;
        end
      end
    end
  end

  // Sampling at posedge deliberately observes the R handshake *before* the
  // master's always_ff latches a sticky error.  That makes bus_err's sampling
  // requirement precise: it must be visible on the faulting beat itself.
  int pre_ack_count, pre_missing_ack_count;
  int priming_ack_count, fault_ack_count, following_ack_count, outside_ack_count;
  int fault_buserr_low_count;
  logic fault_seen;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pre_ack_count        <= 0;
      pre_missing_ack_count <= 0;
      priming_ack_count    <= 0;
      fault_ack_count      <= 0;
      following_ack_count  <= 0;
      outside_ack_count    <= 0;
      fault_buserr_low_count <= 0;
      fault_seen           <= 1'b0;
    end else begin
      if ((m_ack !== 1'b0) && !(rvalid && rready))
        outside_ack_count <= outside_ack_count + 1;
      if (rvalid && rready) begin
        if ((stream_ar == FAULT_AR_U8) && (stream_beat == FAULT_BEAT_U4)) begin
          fault_seen <= 1'b1;
          if (m_ack !== 1'b0) fault_ack_count <= fault_ack_count + 1;
          if (bus_err !== 1'b1) fault_buserr_low_count <= fault_buserr_low_count + 1;
        end else if (!NARROW && !FAULT_PRIMING && (stream_ar == FAULT_AR_U8) &&
                     (stream_beat < FAULT_BEAT_U4)) begin
          if (m_ack === 1'b1) pre_ack_count <= pre_ack_count + 1;
          else                 pre_missing_ack_count <= pre_missing_ack_count + 1;
        end else if ((stream_ar == FAULT_AR_U8) &&
                     (stream_beat > FAULT_BEAT_U4)) begin
          if (m_ack !== 1'b0) following_ack_count <= following_ack_count + 1;
        end else if (m_ack !== 1'b0) begin
          // Every other beat is priming (line) and must remain hidden.
          priming_ack_count <= priming_ack_count + 1;
        end
      end
    end
  end

  initial begin : run_case
    int guard;
    int local_errs;
    done = 1'b0;
    errs = 0;
    m_req = 1'b0;
    wait (rst_n === 1'b1);
    repeat (3) @(posedge clk);
    @(negedge clk); m_req = 1'b1;

    // Keep m_req asserted through the error beat just like a real fill/bypass
    // client.  Drop it immediately afterwards so a fatal access cannot be
    // mistaken for a new architectural request once the channel drains.
    guard = 0;
    while (!fault_seen && guard < 300) begin
      @(posedge clk);
      guard++;
    end
    if (!fault_seen) begin
      $display("FAIL [%s]: injected RRESP handshake was never observed", TAG);
    end
    @(negedge clk); m_req = 1'b0;

    guard = 0;
    while (!m_idle && guard < 300) begin
      @(posedge clk);
      guard++;
    end
    // One extra edge proves a late, unintended AR cannot appear immediately on
    // the transition to IDLE after the faulted response stream.
    repeat (2) @(posedge clk);

    local_errs = 0;
    if (!fault_seen) local_errs++;
    if (ar_count != EXPECT_ARS) begin
      $display("FAIL [%s]: AR count got %0d exp %0d (replay after fault?)",
               TAG, ar_count, EXPECT_ARS);
      local_errs++;
    end
    if (r_handshakes != EXPECT_RHS) begin
      $display("FAIL [%s]: R handshakes got %0d exp %0d (did not drain)",
               TAG, r_handshakes, EXPECT_RHS);
      local_errs++;
    end
    if (rlast_count != EXPECT_ARS || rlast_shape_bad != 0) begin
      $display("FAIL [%s]: RLAST count=%0d exp=%0d shape_bad=%0d",
               TAG, rlast_count, EXPECT_ARS, rlast_shape_bad);
      local_errs++;
    end
    if (ar_shape_bad != 0) begin
      $display("FAIL [%s]: malformed AR count=%0d", TAG, ar_shape_bad);
      local_errs++;
    end
    if (NARROW) begin
      if (pre_ack_count != 0 || pre_missing_ack_count != 0) begin
        $display("FAIL [%s]: narrow unexpectedly recorded pre-fault delivery", TAG);
        local_errs++;
      end
    end else if (pre_ack_count != EXPECT_PRE_ACK || pre_missing_ack_count != 0) begin
      $display("FAIL [%s]: delivered pre-fault acks=%0d missing=%0d exp=%0d/0",
               TAG, pre_ack_count, pre_missing_ack_count, EXPECT_PRE_ACK);
      local_errs++;
    end
    if (priming_ack_count != 0 || fault_ack_count != 0 ||
        following_ack_count != 0 || outside_ack_count != 0) begin
      $display("FAIL [%s]: forbidden acks priming=%0d fault=%0d following=%0d outside=%0d",
               TAG, priming_ack_count, fault_ack_count, following_ack_count,
               outside_ack_count);
      local_errs++;
    end
    if (fault_buserr_low_count != 0) begin
      $display("FAIL [%s]: bus_err was low on %0d fault handshake(s)",
               TAG, fault_buserr_low_count);
      local_errs++;
    end
    if (bus_err !== 1'b1) begin
      $display("FAIL [%s]: bus_err did not remain sticky", TAG);
      local_errs++;
    end
    if (!m_idle) begin
      $display("FAIL [%s]: master did not return idle after R channel drain", TAG);
      local_errs++;
    end
    errs = local_errs;
    if (local_errs == 0)
      $display("AXI-RRESP-CONTAIN-CASE-OK [%s] ar=%0d r=%0d pre_ack=%0d",
               TAG, ar_count, r_handshakes, pre_ack_count);
    else
      $display("AXI-RRESP-CONTAIN-CASE-FAIL [%s] errs=%0d", TAG, local_errs);
    done = 1'b1;
  end
endmodule

module tb_axi_rresp_contain;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic line_done, priming_done, priming_final_done, narrow_done, narrow_safe_done;
  int line_errs, priming_errs, priming_final_errs, narrow_errs, narrow_safe_errs;

  axi_rresp_contain_case #(.NARROW(1'b0), .TAG("cache-line")) line_case (
      .clk(clk), .rst_n(rst_n), .done(line_done), .errs(line_errs)
  );
  axi_rresp_contain_case #(.NARROW(1'b0), .FAULT_PRIMING(1'b1), .TAG("priming")) priming_case (
      .clk(clk), .rst_n(rst_n), .done(priming_done), .errs(priming_errs)
  );
  // Faulting the LAST discarded cache-line beat proves the replay decision uses
  // the handshake-time fatal term, not only rresp_err after its sequential update.
  axi_rresp_contain_case #(.NARROW(1'b0), .FAULT_PRIMING(1'b1), .FAULT_BEAT(7),
                          .TAG("priming-final")) priming_final_case (
      .clk(clk), .rst_n(rst_n), .done(priming_final_done), .errs(priming_final_errs)
  );
  axi_rresp_contain_case #(.NARROW(1'b1), .TAG("narrow")) narrow_case (
      .clk(clk), .rst_n(rst_n), .done(narrow_done), .errs(narrow_errs)
  );
  // NARROW_REPLAY_SAFE makes the first/only narrow response a priming beat.
  // A fault there must stop the second AR before the sticky flag appears next cycle.
  axi_rresp_contain_case #(.NARROW(1'b1), .REPLAY_SAFE(1'b1), .TAG("narrow-replay-safe"))
      narrow_safe_case (
      .clk(clk), .rst_n(rst_n), .done(narrow_safe_done), .errs(narrow_safe_errs)
  );

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
  end

  initial begin
    wait (line_done && priming_done && priming_final_done && narrow_done && narrow_safe_done);
    if (line_errs == 0 && priming_errs == 0 && priming_final_errs == 0 &&
        narrow_errs == 0 && narrow_safe_errs == 0)
      $display("AXI-RRESP-CONTAIN-GATE-OK (bad R beats blocked at the master boundary)");
    else
      $display("AXI-RRESP-CONTAIN-GATE-FAIL line_errs=%0d priming_errs=%0d priming_final_errs=%0d narrow_errs=%0d narrow_safe_errs=%0d",
               line_errs, priming_errs, priming_final_errs, narrow_errs, narrow_safe_errs);
    $finish;
  end

  initial begin
    #100000;
    $display("AXI-RRESP-CONTAIN-GATE-FAIL (timeout -- R channel did not drain)");
    $finish;
  end
endmodule
