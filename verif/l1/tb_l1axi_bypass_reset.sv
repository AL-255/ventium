// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Default (CDC_BYPASS) L1/AXI read-reset-coupling regression.
//
// The single-clock seam still exposes separate core_rst_n and axi_rst_n pins.
// An AXI-only reset must clear both the cache-side producer and the AXI master:
// otherwise a held AR/AW or terminal response state can outlive the fabric that
// owns it.  This test deliberately asserts only axi_rst_n in two vulnerable
// READ phases and requires a clean, ordinary cache-line refill after each release:
//
//   1. ARVALID held while ARREADY is low: reset must asynchronously withdraw
//      ARVALID and quiesce every response-ready output.
//   2. An accepted cold-fill AR with RVALID about to stream: reset must abandon
//      the transaction without an architectural ack or bus error, then restart
//      with exactly two fresh ARs / sixteen R beats (priming + delivery).
//
// It intentionally does NOT claim transparent recovery of posted writes.  A
// store can be architecturally admitted before AW/W/B, and an independent fabric
// reset cannot safely decide whether to replay it.  The platform must couple an
// unexpected AXI reset to a global core abort/reset, or issue a planned reset
// only after shutdown+m_idle; m_idle after an emergency reset is not evidence
// that pre-reset posted writes reached memory.

module tb_l1axi_bypass_reset;
  localparam int unsigned ADDR_W = 40;
  localparam int unsigned LINE_BEATS = 8;
  localparam logic [31:0] READ_A = 32'h0000_1024;
  localparam logic [31:0] READ_B = 32'h0000_2084;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // Start high and create a real reset edge so every asynchronous state element
  // is initialized identically in event-driven simulators and in hardware.
  logic core_rst_n = 1'b1, axi_rst_n = 1'b1;
  initial begin
    #1;
    core_rst_n = 1'b0;
    axi_rst_n  = 1'b0;
  end

  logic c_req, c_we;
  logic [31:0] c_addr, c_wdata, c_rdata;
  logic [3:0] c_wstrb;
  logic c_ack, bus_err, m_idle, ic_nocache_unused, smm_flush_o;

  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0] awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0] awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0] arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0] arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(
      .ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'hFFFF_FFFF)
  ) dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .core_next_req(1'b0), .core_next_commit(1'b0),
      .core_next_addr(32'd0), .core_next_wstrb(4'd0), .core_next_ready(),
`endif

      .core_clk(clk), .core_rst_n(core_rst_n), .axi_clk(clk), .axi_rst_n(axi_rst_n),
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .core_lin(c_addr),
      .smm_active(1'b0), .smbase(32'h0003_0000), .smm_flush_o(smm_flush_o),
      .core_lock(1'b0), .core_lock_hold(1'b0),
      .core_wdata(c_wdata), .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      .core_ic_nocache(ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
      .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
      .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
      .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
      .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // A registered, protocol-correct AXI read responder.  It can hold ARREADY
  // low for the first reset phase; after an AR handshake it emits precisely the
  // requested INCR/WRAP burst and holds RVALID until RREADY.
  typedef enum logic { RESP_IDLE, RESP_DATA } resp_state_e;
  resp_state_e rsp_st;
  logic [ADDR_W-1:0] rsp_addr;
  logic [7:0] rsp_beat, rsp_len;
  logic [1:0] rsp_burst;
  logic arready_enable;
  logic [2:0] rsp_wrap_word;
  logic [31:0] rsp_word_addr;

  function automatic logic [31:0] mem_word(input logic [31:0] addr);
    mem_word = 32'hC0DE_0000 ^ addr;
  endfunction

  assign awready = axi_rst_n;
  assign wready  = axi_rst_n;
  assign bid     = 4'd0;
  assign bresp   = 2'b00;
  assign bvalid  = 1'b0;
  assign arready = axi_rst_n && arready_enable && (rsp_st == RESP_IDLE);
  assign rid     = 4'd0;
  assign rresp   = 2'b00;
  assign rvalid  = axi_rst_n && (rsp_st == RESP_DATA);
  assign rsp_wrap_word = rsp_addr[4:2] + rsp_beat[2:0];
  assign rsp_word_addr = (rsp_burst == 2'b10)
      ? {rsp_addr[31:5], rsp_wrap_word, 2'b00}
      : rsp_addr[31:0] + {22'd0, rsp_beat, 2'b00};
  assign rdata   = mem_word(rsp_word_addr);
  assign rlast   = rvalid && (rsp_beat == rsp_len);

  always_ff @(posedge clk or negedge axi_rst_n) begin
    if (!axi_rst_n) begin
      rsp_st   <= RESP_IDLE;
      rsp_addr <= '0;
      rsp_beat <= 8'd0;
      rsp_len  <= 8'd0;
      rsp_burst <= 2'b01;
    end else unique case (rsp_st)
      RESP_IDLE: if (arvalid && arready) begin
                   rsp_st   <= RESP_DATA;
                   rsp_addr <= araddr;
                   rsp_beat <= 8'd0;
                   rsp_len  <= arlen;
                   rsp_burst <= arburst;
                 end
      RESP_DATA: if (rvalid && rready) begin
                   if (rlast) begin
                     rsp_st <= RESP_IDLE;
                     rsp_beat <= 8'd0;
                   end else rsp_beat <= rsp_beat + 8'd1;
                 end
      default: rsp_st <= RESP_IDLE;
    endcase
  end

  int errors;
  int ar_total, r_total, ar_shape_bad, rlast_shape_bad;
  // The reset bridge deliberately keeps the D$ clear but sends the core I$
  // one recovery invalidate after the seam becomes live.  Count it from the
  // raw AXI-reset edge so a pulse shorter than a core clock is covered too.
  int smm_recovery_flushes;
  always @(posedge clk or negedge axi_rst_n) begin
    if (!axi_rst_n) smm_recovery_flushes <= 0;
    else if (smm_flush_o) smm_recovery_flushes <= smm_recovery_flushes + 1;
  end
  always @(posedge clk) begin
    if (axi_rst_n) begin
      if (arvalid && arready) begin
        ar_total = ar_total + 1;
        if (arlen != 8'(LINE_BEATS-1) || arsize != 3'd2 ||
            arburst != 2'b10 ||
            ((araddr != ADDR_W'(READ_A)) &&
             (araddr != ADDR_W'(READ_B))))
          ar_shape_bad = ar_shape_bad + 1;
      end
      if (rvalid && rready) begin
        r_total = r_total + 1;
        if (rlast != (rsp_beat == rsp_len)) rlast_shape_bad = rlast_shape_bad + 1;
      end
    end
  end

  task automatic fail(input string what);
    begin
      $display("  FAIL: %s", what);
      errors = errors + 1;
    end
  endtask

  task automatic wait_for_idle(input string phase);
    int guard;
    begin
      guard = 0;
      while (m_idle !== 1'b1 && guard < 100) begin
        @(posedge clk); #1;
        guard++;
      end
      if (m_idle !== 1'b1)
        fail($sformatf("%s: AXI fill did not drain", phase));
    end
  endtask

  task automatic require_reset_quiet(input string phase);
    begin
      if (arvalid !== 1'b0 || awvalid !== 1'b0 || wvalid !== 1'b0 ||
          rvalid !== 1'b0 || bvalid !== 1'b0 || rready !== 1'b0 || bready !== 1'b0)
        fail($sformatf("%s: AXI did not quiesce ar=%b aw=%b w=%b r=%b b=%b rr=%b br=%b",
                       phase, arvalid, awvalid, wvalid, rvalid, bvalid, rready, bready));
      if (c_ack !== 1'b0 || bus_err !== 1'b0)
        fail($sformatf("%s: core/reset state ack=%b err=%b",
                       phase, c_ack, bus_err));
      if (smm_flush_o !== 1'b0)
        fail($sformatf("%s: reset-recovery I$ flush leaked while seam reset", phase));
    end
  endtask

  task automatic wait_for_ack(input string phase, output logic [31:0] data);
    int guard;
    begin
      data = 32'hXXXX_XXXX;
      guard = 0;
      while ((c_ack !== 1'b1) && (guard < 1000)) begin
        @(posedge clk); #1;
        guard = guard + 1;
      end
      if (c_ack !== 1'b1)
        fail($sformatf("%s: core request never acknowledged", phase));
      else
        data = c_rdata;
    end
  endtask

  initial begin : stimulus
    int guard;
    int ar_base, r_base;
    logic [31:0] data;

    errors = 0;
    ar_total = 0; r_total = 0; ar_shape_bad = 0; rlast_shape_bad = 0;
    c_req = 1'b0; c_we = 1'b0; c_addr = 32'd0; c_wdata = 32'd0; c_wstrb = 4'd0;
    arready_enable = 1'b0;

    repeat (4) @(posedge clk);
    @(negedge clk) begin
      core_rst_n = 1'b1;
      axi_rst_n  = 1'b1;
    end
    repeat (3) @(posedge clk);

    // [1] Hold ARVALID without an address handshake, then reset only the AXI
    // side.  The master and L1 must drop the held transaction asynchronously.
    @(negedge clk) begin
      c_req = 1'b1;
      c_we = 1'b0;
      c_addr = READ_A;
      c_wstrb = 4'd0;
    end
    guard = 0;
    while ((arvalid !== 1'b1) && (guard < 200)) begin
      @(posedge clk); #1;
      guard = guard + 1;
    end
    if (arvalid !== 1'b1)
      fail("held-AR phase never reached ARVALID");
    else if (arready !== 1'b0)
      fail("held-AR phase did not keep ARREADY low");
    @(negedge clk) axi_rst_n = 1'b0;
    #1;
    require_reset_quiet("AXI-only reset while ARVALID held");
    if (ar_total != 0 || r_total != 0)
      fail($sformatf("held-AR reset accepted traffic ar=%0d r=%0d", ar_total, r_total));

    // Release after only two simulator ticks -- shorter than one core period.
    // The async assertion plus two-edge release bridge must still reset ven_l1d
    // synchronously, then issue exactly one I$ recovery flush.  A clean cold
    // fill must restart; the old held AR is not allowed to survive.
    #1 begin
      arready_enable = 1'b1;
      axi_rst_n = 1'b1;
    end
    ar_base = ar_total;
    r_base  = r_total;
    wait_for_ack("post-held-AR reset read", data);
    if (data !== mem_word(READ_A))
      fail($sformatf("post-held-AR reset data=%08x exp=%08x", data, mem_word(READ_A)));
    @(negedge clk) c_req = 1'b0;
    wait_for_idle("post-held-AR reset read");
    if (ar_total != ar_base + 2 || r_total != r_base + 16)
      fail($sformatf("post-held-AR reset shape ar=%0d r=%0d exp=2/16",
                     ar_total-ar_base, r_total-r_base));
    if (smm_recovery_flushes != 1)
      fail($sformatf("post-held-AR reset I$ recovery flushes=%0d exp=1",
                     smm_recovery_flushes));
    if (bus_err !== 1'b0 || m_idle !== 1'b1)
      fail("post-held-AR reset read did not finish healthy/idle");

    // [2] Let the first priming AR handshake, then reset before its first R
    // beat is sampled.  This exercises reset of an accepted master transaction,
    // not merely reset of a held address channel.
    ar_base = ar_total;
    r_base  = r_total;
    @(negedge clk) begin
      c_req = 1'b1;
      c_addr = READ_B;
    end
    guard = 0;
    while ((ar_total != ar_base + 1) && (guard < 200)) begin
      @(posedge clk); #1;
      guard = guard + 1;
    end
    if (ar_total != ar_base + 1)
      fail("mid-fill phase did not accept its first AR");
    @(negedge clk) axi_rst_n = 1'b0;
    #1;
    require_reset_quiet("AXI-only reset after accepted AR");
    if (r_total != r_base)
      fail($sformatf("mid-fill reset consumed %0d R beat(s) before reset", r_total-r_base));

    // The request stays live through reset; release creates one complete new
    // priming/delivery pair.  Include the abandoned pre-reset AR in the count
    // so a stale AR replay or a missing restart cannot hide.
    repeat (3) @(posedge clk);
    @(negedge clk) axi_rst_n = 1'b1;
    wait_for_ack("post-mid-fill reset read", data);
    if (data !== mem_word(READ_B))
      fail($sformatf("post-mid-fill reset data=%08x exp=%08x", data, mem_word(READ_B)));
    @(negedge clk) c_req = 1'b0;
    wait_for_idle("post-mid-fill reset read");
    if (ar_total != ar_base + 3 || r_total != r_base + 16)
      fail($sformatf("post-mid-fill reset shape ar=%0d r=%0d exp=3/16 (1 abandoned + 2 fresh)",
                     ar_total-ar_base, r_total-r_base));
    if (smm_recovery_flushes != 1)
      fail($sformatf("post-mid-fill reset I$ recovery flushes=%0d exp=1",
                     smm_recovery_flushes));
    if (ar_shape_bad != 0 || rlast_shape_bad != 0)
      fail($sformatf("responder saw malformed AXI shape ar_bad=%0d rlast_bad=%0d",
                     ar_shape_bad, rlast_shape_bad));
    if (bus_err !== 1'b0 || m_idle !== 1'b1)
      fail("post-mid-fill reset read did not finish healthy/idle");

    if (errors == 0)
      $display("L1AXIBYPASSRESET-GATE-OK (AXI-only reset clears held and accepted default-seam READ traffic)");
    else
      $display("L1AXIBYPASSRESET-GATE-FAIL (%0d error(s))", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("L1AXIBYPASSRESET-GATE-FAIL (timeout)");
    $finish;
  end
endmodule : tb_l1axi_bypass_reset
