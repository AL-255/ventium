// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// tb_l1axi_cdc_rresp.sv -- deliberately faulted RRESP containment through the
// *dual-clock* L1/AXI bridge.
//
// The direct AXI-master gate proves that a bad R beat is not acknowledged at
// the master boundary.  That is necessary but not sufficient in +VEN_AXI_CDC:
// three good words of the delivered burst can already reside in the response
// FIFO when the error level crosses back to core_clk.  A bridge which keeps
// draining those words can make a failed fill look complete, or can launch a
// replay after the master has drained the bad burst.
//
// This focused 5:3 core:AXI-clock regression uses a small registered responder
// (not the shared BFM) so it can make the AXI protocol correct while injecting
// precisely one SLVERR:
//
//   AR #0: normal 8-beat priming fill, all RRESP=OKAY;
//   AR #1: normal 8-beat delivered fill, SLVERR only at beat 3, RLAST at beat 7.
//
// The scoreboard proves that the bad beat is neither axm_ack'd nor written into
// u_cdc's response FIFO, the master drains the whole R channel and stays idle,
// the bridge takes C_FAULT/A_FAULT with no completion from the bad or following
// beats, and
// an AXI-only raw reset clears the coupled terminal state/FIFOs.  The responder
// is then made clean and a fresh cacheable read must refill correctly.
//
// The runner deliberately uses --no-assert because this test intentionally
// violates ven_axi_master.rresp_okay.  Normal builds retain that assertion.

module tb_l1axi_cdc_rresp;
  localparam int unsigned ADDR_W      = 40;
  localparam int unsigned LINE_BEATS  = 8;
  localparam int unsigned FAULT_AR    = 1;  // AR0 is priming; AR1 is delivered
  localparam int unsigned FAULT_BEAT  = 3;
  localparam logic [31:0] READ_ADDR   = 32'h0000_1024;
  localparam logic [ADDR_W-1:0] LINE_AXI_ADDR = {8'd0, READ_ADDR};

  // Deliberately non-equal/coprime periods: core is slower than AXI.  This lets
  // valid response words accumulate in the async FIFO before bus_err reaches
  // the core side, which is the failure mode this gate guards.
  logic core_clk = 1'b0, axi_clk = 1'b0;
  always #5 core_clk = ~core_clk;
  always #3 axi_clk  = ~axi_clk;

  // Start high and explicitly assert reset at t=1.  That creates an actual
  // async-reset edge for every flop (rather than relying on simulator-specific
  // initialization of a signal that merely starts low).
  logic core_rst_n = 1'b1, axi_rst_n = 1'b1;
  initial begin
    #1;
    core_rst_n = 1'b0;
    axi_rst_n  = 1'b0;
  end

  // Core-side request port.
  logic        c_req, c_we;
  logic [31:0] c_addr, c_wdata, c_rdata;
  logic [3:0]  c_wstrb;
  logic        c_ack, bus_err, m_idle, ic_nocache_unused;

  // AXI channels.
  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(
      .ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'hFFFF_FFFF)
  ) dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .core_next_req(1'b0), .core_next_commit(1'b0),
      .core_next_addr(32'd0), .core_next_wstrb(4'd0), .core_next_ready(),
`endif

      .core_clk(core_clk), .core_rst_n(core_rst_n),
      .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .core_lin(c_addr),
      .smm_active(1'b0), .smbase(32'h0003_0000), .smm_flush_o(),
      .core_lock(1'b0), .core_lock_hold(1'b0),
      .core_wdata(c_wdata), .core_wstrb(c_wstrb),
      .core_rdata(c_rdata), .core_ack(c_ack),
      .core_ic_nocache(ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
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

  // No writes are issued, but keep unused AXI slave channels legal and quiet.
  assign awready = 1'b1;
  assign wready  = 1'b1;
  assign bid     = 4'd0;
  assign bresp   = 2'b00;
  assign bvalid  = 1'b0;

  // --------------------------------------------------------------------------
  // Registered AXI read responder.  It accepts one burst at a time, holds RVALID
  // until RREADY, and emits a protocol-correct eight-beat WRAP response.
  // `inject_fault` is testbench state deliberately NOT reset by the DUT reset:
  // after the terminal-fault reset it turns the same responder into clean RAM.
  // --------------------------------------------------------------------------
  typedef enum logic { RESP_IDLE, RESP_DATA } resp_state_e;
  resp_state_e rsp_st;
  logic [7:0]        rsp_seq;
  logic [3:0]        rsp_beat;
  logic [ADDR_W-1:0] rsp_addr;
  logic [1:0]        rsp_burst;
  logic              inject_fault;
  // rsp_seq increments on AR acceptance, so the response currently streaming is
  // ordinal rsp_seq-1: 0 is the discarded priming burst and 1 is the delivered
  // burst where this test injects SLVERR.
  logic [7:0]        active_ar;

  function automatic logic [31:0] response_word(
      input logic [ADDR_W-1:0] base, input logic [3:0] beat,
      input logic [1:0] burst);
    logic [2:0] wrap_word;
    wrap_word = base[4:2] + beat[2:0];
    response_word = 32'hC0DE_0000 ^ ((burst == 2'b10)
        ? {base[31:5], wrap_word, 2'b00}
        : (base[31:0] + {26'd0, beat, 2'b00}));
  endfunction

  assign arready = (rsp_st == RESP_IDLE);
  always_comb begin
    rid    = 4'd0;
    rvalid = 1'b0;
    rdata  = 32'd0;
    rresp  = 2'b00;
    rlast  = 1'b0;
    if (rsp_st == RESP_DATA) begin
      rvalid = 1'b1;
      rdata  = response_word(rsp_addr, rsp_beat, rsp_burst);
      rlast  = (rsp_beat == 4'(LINE_BEATS-1));
      if (inject_fault && (active_ar == 8'(FAULT_AR)) &&
          (rsp_beat == 4'(FAULT_BEAT)))
        rresp = 2'b10;                    // SLVERR, while RLAST remains correct
    end
  end

  always_ff @(posedge axi_clk or negedge axi_rst_n) begin
    if (!axi_rst_n) begin
      rsp_st   <= RESP_IDLE;
      rsp_seq  <= 8'd0;
      rsp_beat <= 4'd0;
      rsp_addr <= '0;
      rsp_burst <= 2'b01;
    end else unique case (rsp_st)
      RESP_IDLE: if (arvalid && arready) begin
                   rsp_st   <= RESP_DATA;
                   rsp_addr <= araddr;
                   rsp_burst <= arburst;
                   rsp_beat <= 4'd0;
                   rsp_seq  <= rsp_seq + 8'd1;
                 end
      RESP_DATA: if (rvalid && rready) begin
                   if (rsp_beat == 4'(LINE_BEATS-1)) begin
                     rsp_st   <= RESP_IDLE;
                     rsp_beat <= 4'd0;
                   end else rsp_beat <= rsp_beat + 4'd1;
                 end
      default: rsp_st <= RESP_IDLE;
    endcase
  end

  // rsp_seq above is the sequence *after* an AR handshake.  The stream's ordinal
  // is therefore rsp_seq-1; keep the derived wire in one place for all monitors.
  assign active_ar = rsp_seq - 8'd1;

  // --------------------------------------------------------------------------
  // Scoreboard monitors.  These counters intentionally survive the raw-reset
  // phase so the test can separately prove the failed transaction's exact shape
  // and the fresh transaction's post-reset shape.
  // --------------------------------------------------------------------------
  int errors;
  int ar_total, r_total, rsp_write_total;
  int ar_shape_bad, rlast_shape_bad;
  int good_pre_ack, missing_pre_ack, forbidden_axm_ack;
  int fault_axm_ack, fault_rsp_write, fault_buserr_low;
  int bridge_ack_total, core_ack_total, fault_state_cack;
  logic [31:0] fault_core_data;
  logic fault_seen;

  initial begin
    errors = 0;
    ar_total = 0; r_total = 0; rsp_write_total = 0;
    ar_shape_bad = 0; rlast_shape_bad = 0;
    good_pre_ack = 0; missing_pre_ack = 0; forbidden_axm_ack = 0;
    fault_axm_ack = 0; fault_rsp_write = 0; fault_buserr_low = 0;
    bridge_ack_total = 0; core_ack_total = 0; fault_state_cack = 0;
    fault_core_data = '0;
    fault_seen = 1'b0;
    inject_fault = 1'b1;
  end

  // AXI-domain monitor: sample at the response handshake edge, before the
  // master latches sticky flags.  This is the only point that can prove the
  // failed word was not admitted to either master or response FIFO.
  always @(posedge axi_clk) begin
    if (axi_rst_n) begin
      if (arvalid && arready) begin
        ar_total = ar_total + 1;
        if (araddr !== LINE_AXI_ADDR || arlen !== 8'(LINE_BEATS-1) ||
            arsize !== 3'd2 || arburst !== 2'b10)
          ar_shape_bad = ar_shape_bad + 1;
      end
      if (rvalid && rready) begin
        r_total = r_total + 1;
        if (rlast !== (rsp_beat == 4'(LINE_BEATS-1)))
          rlast_shape_bad = rlast_shape_bad + 1;
        if (inject_fault && (active_ar == 8'(FAULT_AR)) &&
            (rsp_beat == 4'(FAULT_BEAT))) begin
          fault_seen = 1'b1;
          if (dut.axm_ack !== 1'b0)          fault_axm_ack = fault_axm_ack + 1;
          if (dut.u_cdc.rsp_wr_en !== 1'b0)  fault_rsp_write = fault_rsp_write + 1;
          if (dut.axm_bus_err !== 1'b1)      fault_buserr_low = fault_buserr_low + 1;
        end else if (inject_fault && (active_ar == 8'(FAULT_AR)) &&
                     (rsp_beat < 4'(FAULT_BEAT))) begin
          if (dut.axm_ack === 1'b1) good_pre_ack = good_pre_ack + 1;
          else                       missing_pre_ack = missing_pre_ack + 1;
        end else if (inject_fault && (dut.axm_ack !== 1'b0)) begin
          // Priming, fault-following, and every post-fatal beat must be invisible
          // to the bridge.  (The three pre-fault delivered beats are handled above.)
          forbidden_axm_ack = forbidden_axm_ack + 1;
        end
      end
      if (dut.u_cdc.rsp_wr_en === 1'b1)
        rsp_write_total = rsp_write_total + 1;
    end
  end

  // Core-domain monitor: b_ack is the bridge->ven_l1d backing acknowledgement;
  // c_ack is the architectural completion. Critical-word-first may retire the
  // requested good beat before a later beat's error arrives. That completion
  // cannot be revoked; the sticky fault must prevent any further completion.
  always @(posedge core_clk) begin
    if (dut.core_rst_sync_n) begin
      if (dut.b_ack === 1'b1) bridge_ack_total = bridge_ack_total + 1;
      if (c_ack === 1'b1) begin
        core_ack_total = core_ack_total + 1;
        if (inject_fault) fault_core_data = c_rdata;
      end
      if ((dut.u_cdc.cst == 2'd2) && (dut.u_cdc.c_ack !== 1'b0))
        fault_state_cack = fault_state_cack + 1;
    end
  end

  task automatic fail(input string what);
    begin
      $display("  FAIL %s", what);
      errors = errors + 1;
    end
  endtask

  task automatic wait_cdc_idle(input string phase);
    int guard;
    begin
      guard = 0;
      while ((dut.u_cdc.cst !== 2'd0 || dut.u_cdc.ast !== 2'd0 ||
              dut.u_cdc.a_req !== 1'b0) && guard < 1000) begin
        @(posedge core_clk);
        guard++;
      end
      if (guard == 1000)
        fail($sformatf("%s: CDC did not return idle", phase));
    end
  endtask

  task automatic wait_core_reset_release;
    begin
      // Two synchronized-release flops, plus a few edges for the FIFO pointer
      // synchronizers.  The fixed bound is deliberately generous for 5:3 clocks.
      repeat (8) @(posedge core_clk);
      repeat (8) @(posedge axi_clk);
      if (dut.core_rst_sync_n !== 1'b1 || dut.axi_rst_sync_n !== 1'b1)
        fail("coupled CDC reset did not release both domains");
    end
  endtask

  task automatic wait_axi_drain(input string phase);
    int guard;
    begin
      guard = 0;
      while ((m_idle !== 1'b1) && (guard < 1000)) begin
        @(posedge axi_clk);
        guard = guard + 1;
      end
      if (m_idle !== 1'b1)
        fail($sformatf("%s: AXI master did not return m_idle", phase));
    end
  endtask

  task automatic wait_buserr_sync;
    int guard;
    begin
      guard = 0;
      while ((bus_err !== 1'b1) && (guard < 1000)) begin
        @(posedge core_clk);
        guard = guard + 1;
      end
      if (bus_err !== 1'b1)
        fail("fatal RRESP did not synchronize bus_err to core domain");
      // bus_err becomes visible on an NBA edge; give C_BUSY its next core edge
      // to enter C_FAULT before inspecting the terminal contract.
      repeat (2) @(posedge core_clk);
    end
  endtask

  initial begin : stimulus
    int guard;
    int fault_ar_total, fault_r_total, fault_rsp_total;
    int fault_bridge_acks, fault_core_acks;
    int clean_ar_base, clean_r_base, clean_core_base;
    logic [31:0] clean_data;

    c_req = 1'b0; c_we = 1'b0; c_addr = 32'd0;
    c_wdata = 32'd0; c_wstrb = 4'd0;

    // Initial coupled reset release.
    repeat (4) @(posedge core_clk);
    @(negedge core_clk); core_rst_n = 1'b1;
    @(negedge axi_clk);  axi_rst_n  = 1'b1;
    wait_core_reset_release();

    // Hold the architectural request through the failed burst.  A broken CDC
    // bridge must not turn that still-live request into AR #2 after drain.
    @(negedge core_clk);
    c_req = 1'b1; c_we = 1'b0; c_addr = READ_ADDR; c_wstrb = 4'd0;

    guard = 0;
    while (!fault_seen && guard < 1000) begin
      @(posedge axi_clk);
      guard = guard + 1;
    end
    if (!fault_seen)
      fail("injected AR1 beat3 SLVERR was not observed");

    // AXI is allowed (and required) to drain all 16 protocol beats; only the
    // architectural delivery path must stop at the fault boundary.
    guard = 0;
    while ((r_total < 16) && (guard < 1000)) begin
      @(posedge axi_clk);
      guard = guard + 1;
    end
    if (r_total != 16)
      fail($sformatf("failed fill did not fully drain R channel (got %0d/16 beats)", r_total));
    wait_axi_drain("faulted fill");
    // Catch a delayed replay just after the master first becomes idle.
    repeat (4) @(posedge axi_clk);
    wait_buserr_sync();

    fault_ar_total    = ar_total;
    fault_r_total     = r_total;
    fault_rsp_total   = rsp_write_total;
    fault_bridge_acks = bridge_ack_total;
    fault_core_acks   = core_ack_total;

    // Exact failed-transaction contract.
    if (fault_ar_total != 2)
      fail($sformatf("faulted fill issued %0d ARs, expected exactly 2 (no replay)", fault_ar_total));
    if (fault_r_total != 16)
      fail($sformatf("faulted fill consumed %0d R beats, expected 16", fault_r_total));
    if (ar_shape_bad != 0 || rlast_shape_bad != 0)
      fail($sformatf("responder saw malformed AXI shape ar_bad=%0d rlast_bad=%0d",
                     ar_shape_bad, rlast_shape_bad));
    if (good_pre_ack != 3 || missing_pre_ack != 0)
      fail($sformatf("pre-fault delivered acks got good=%0d missing=%0d, expected 3/0",
                     good_pre_ack, missing_pre_ack));
    if (fault_axm_ack != 0 || fault_rsp_write != 0 || fault_buserr_low != 0)
      fail($sformatf("bad beat escaped containment axm_ack=%0d rsp_wr=%0d buserr_low=%0d",
                     fault_axm_ack, fault_rsp_write, fault_buserr_low));
    if (forbidden_axm_ack != 0)
      fail($sformatf("priming/following beat was acknowledged %0d time(s)", forbidden_axm_ack));
    if (fault_rsp_total != 3)
      fail($sformatf("response FIFO accepted %0d words, expected only 3 good pre-fault words",
                     fault_rsp_total));
    if (fault_bridge_acks >= LINE_BEATS)
      fail($sformatf("bridge handed L1 %0d backing acks (must be < %0d)",
                     fault_bridge_acks, LINE_BEATS));
    if (fault_core_acks != 1 || fault_core_data !== (32'hC0DE_0000 ^ READ_ADDR))
      fail($sformatf("critical-first completion count/data=%0d/%08x expected 1/%08x",
                     fault_core_acks, fault_core_data, (32'hC0DE_0000 ^ READ_ADDR)));
    if (bus_err !== 1'b1)
      fail("bus_err was not sticky in core domain after failed fill");
    if (m_idle !== 1'b1)
      fail("master was not idle after draining faulted fill");
    // C_FAULT/A_FAULT are deliberately reset-only terminal states (2'd2 by the
    // local enum encoding).  The hierarchical checks make that policy explicit.
    if (dut.u_cdc.cst !== 2'd2 || dut.u_cdc.ast !== 2'd2)
      fail($sformatf("CDC did not enter C_FAULT/A_FAULT (cst=%0d ast=%0d)",
                     dut.u_cdc.cst, dut.u_cdc.ast));
    if (dut.u_cdc.a_req !== 1'b0 || dut.u_cdc.c_ack !== 1'b0 ||
        dut.u_cdc.rsp_wr_en !== 1'b0 || dut.axm_ack !== 1'b0)
      fail("terminal CDC state still exposed a request or acknowledgement");
    if (fault_state_cack != 0)
      fail($sformatf("C_FAULT emitted c_ack on %0d core edge(s)", fault_state_cack));

    // No normal completion is possible after a fatal fault.  Reset ONLY the raw
    // AXI domain: rst_comb_n must immediately reset BOTH bridge domains/FIFOs.
    @(negedge core_clk); c_req = 1'b0;
    inject_fault = 1'b0;                 // clean responder after reset
    @(negedge axi_clk); axi_rst_n = 1'b0;
    #1;
    if (dut.core_rst_sync_n !== 1'b0 || dut.axi_rst_sync_n !== 1'b0)
      fail("AXI-only raw reset did not asynchronously couple into both reset bridges");
    if (dut.u_cdc.cst !== 2'd0 || dut.u_cdc.ast !== 2'd0 ||
        dut.u_cdc.a_req !== 1'b0 || dut.u_cdc.c_ack !== 1'b0)
      fail("AXI-only raw reset did not clear C_FAULT/A_FAULT state");
    if (dut.u_cdc.cmd_empty !== 1'b1 || dut.u_cdc.rsp_empty !== 1'b1 ||
        dut.u_cdc.u_cmd.wbin !== '0 || dut.u_cdc.u_cmd.rbin !== '0 ||
        dut.u_cdc.u_rsp.wbin !== '0 || dut.u_cdc.u_rsp.rbin !== '0)
      fail("coupled reset did not clear asynchronous FIFO state");
    if (bus_err !== 1'b0)
      fail("coupled reset did not clear synchronized bus_err");

    repeat (3) @(posedge axi_clk);
    @(negedge axi_clk); axi_rst_n = 1'b1;
    wait_core_reset_release();
    if (bus_err !== 1'b0 || dut.u_cdc.cst !== 2'd0 || dut.u_cdc.ast !== 2'd0 ||
        dut.u_cdc.cmd_empty !== 1'b1 || dut.u_cdc.rsp_empty !== 1'b1)
      fail("post-reset bridge did not restart cleanly at IDLE with empty FIFOs");

    // Fresh cacheable read proves reset recovery, not merely quiescence.  The
    // responder remains protocol-clean, so it must incur the ordinary two ARs
    // (priming + delivered) and return the delivered line word.
    clean_ar_base   = ar_total;
    clean_r_base    = r_total;
    clean_core_base = core_ack_total;
    clean_data      = 32'hXXXX_XXXX;
    @(negedge core_clk);
    c_req = 1'b1; c_we = 1'b0; c_addr = READ_ADDR; c_wstrb = 4'd0;
    guard = 0;
    while ((c_ack !== 1'b1) && (guard < 3000)) begin
      @(posedge core_clk);
      guard = guard + 1;
    end
    if (c_ack !== 1'b1)
      fail("clean post-reset cacheable read never completed");
    else
      clean_data = c_rdata;
    @(negedge core_clk); c_req = 1'b0;
    wait_axi_drain("clean post-reset fill");
    wait_cdc_idle("clean post-reset fill");

    if (clean_data !== (32'hC0DE_0000 ^ (READ_ADDR)))
      fail($sformatf("clean post-reset read data=%08x expected=%08x", clean_data,
                     (32'hC0DE_0000 ^ READ_ADDR)));
    if (ar_total != clean_ar_base + 2)
      fail($sformatf("clean post-reset read issued %0d ARs, expected 2",
                     ar_total-clean_ar_base));
    if (r_total != clean_r_base + 16)
      fail($sformatf("clean post-reset read consumed %0d R beats, expected 16",
                     r_total-clean_r_base));
    if (core_ack_total != clean_core_base + 1)
      fail($sformatf("clean post-reset read produced %0d core acks, expected 1",
                     core_ack_total-clean_core_base));
    if (bus_err !== 1'b0 || dut.u_cdc.cst !== 2'd0 || dut.u_cdc.ast !== 2'd0 ||
        dut.u_cdc.a_req !== 1'b0)
      fail("clean post-reset access did not finish with healthy idle CDC state");

    if (errors == 0)
      $display("L1AXICDCRRESP-GATE-OK (bad RRESP contained across 5:3 CDC; coupled reset recovers)");
    else
      $display("L1AXICDCRRESP-GATE-FAIL (%0d error(s))", errors);
    $finish;
  end

  initial begin
    #250000;
    $display("L1AXICDCRRESP-GATE-FAIL (timeout -- CDC fault or reset recovery hang)");
    $finish;
  end
endmodule : tb_l1axi_cdc_rresp
