// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_cdc_dma_reset.sv -- directed reset-release regression for
// the local DMA requester in the dual-clock L1/AXI configuration.
//
// A request held by an external requester while the raw reset deasserts must
// NOT reach the northbridge seam before the core-domain reset bridge releases
// the L1 fabric.  `dma_lock_rst_n` therefore follows `core_rst_sync_n` in the
// +VEN_AXI_CDC build, rather than the raw core_rst_n input.  This test keeps a
// DMA write request asserted through both raw-reset releases and checks:
//
//   * no select / no in-flight ownership while either raw reset is asserted;
//   * after both raw resets are high, no select during every core-reset-sync
//     latency cycle (including the instant raw core_rst_n rises);
//   * once the core-side synchronizer releases, the held request can select,
//     then latches as in-flight on the following core clock; and
//   * dropping only axi_rst_n asynchronously clears the coupled core-side
//     DMA state again, despite core_rst_n remaining high.
//
// The no-L2 configuration deliberately ties nb_dma_ack low, which is ideal
// here: the accepted request remains observable as dma_inflight without a
// downstream responder.  The test is intentionally a small seam-level build;
// it does not issue any core or AXI traffic.

module tb_l1axi_cdc_dma_reset;
  localparam int ADDR_W = 40;

  logic core_clk = 1'b0, axi_clk = 1'b0;
  always #5 core_clk = ~core_clk;
  always #3 axi_clk  = ~axi_clk;

  // Start high so the explicit assertion at t=1 causes an async-reset event
  // for every flop, even in simulators that do not schedule an event for an
  // initial value of zero.
  logic core_rst_n = 1'b1, axi_rst_n = 1'b1;

  // Quiescent core-side requester.
  logic c_req, c_we;
  logic [31:0] c_addr, c_wdata, c_rdata;
  logic [3:0]  c_wstrb;
  logic c_ack, bus_err, m_idle, ic_nocache_unused;

  // DMA requester under test. d_req stays asserted from before raw reset
  // assertion through the reset-release sequence and the later select.
  logic d_req, d_we;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic [3:0]  d_wstrb;
  logic d_ack;

  // AXI ports are deliberately idle: no core request is issued in this test.
  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0] awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0] awprot; logic [3:0] awqos; logic awvalid;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid;
  logic bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0] arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0] arprot; logic [3:0] arqos; logic arvalid;
  logic rready;

  ventium_l1_axi #(
      .ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'hFFFF_FFFF),
      .WATCHDOG(32)
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
      .dma_req(d_req), .dma_we(d_we), .dma_addr(d_addr), .dma_wdata(d_wdata),
      .dma_wstrb(d_wstrb), .dma_rdata(d_rdata), .dma_ack(d_ack),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
      .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
      .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
      .m_axi_awvalid(awvalid), .m_axi_awready(1'b0),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(1'b0),
      .m_axi_bid(4'd0), .m_axi_bresp(2'd0), .m_axi_bvalid(1'b0),
      .m_axi_bready(bready),
      .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(1'b0),
      .m_axi_rid(4'd0), .m_axi_rdata(32'd0), .m_axi_rresp(2'd0),
      .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0), .m_axi_rready(rready)
  );

  int fails = 0;

  task automatic fail(input string what);
    begin
      $display("  FAIL %s", what);
      fails++;
    end
  endtask

  // Called only while the core-side synchronized reset is expected to be
  // asserted. Check the reset bridge itself as well as the two externally
  // meaningful DMA seam observables.
  task automatic expect_dma_quiet(input string phase);
    begin
      if (dut.core_rst_sync_n !== 1'b0)
        fail($sformatf("%s: core_rst_sync_n released early (%b)", phase,
                       dut.core_rst_sync_n));
      if (dut.dma_lock_rst_n !== 1'b0)
        fail($sformatf("%s: dma_lock_rst_n released before core reset bridge (%b)", phase,
                       dut.dma_lock_rst_n));
      if (dut.nb_dma_req !== 1'b0)
        fail($sformatf("%s: held DMA request reached nb seam before synchronized release (%b)",
                       phase, dut.nb_dma_req));
      if (dut.dma_inflight !== 1'b0)
        fail($sformatf("%s: dma_inflight became live before synchronized release (%b)",
                       phase, dut.dma_inflight));
    end
  endtask

  initial begin : stimulus
    int pre_sync_edges;

    c_req = 1'b0; c_we = 1'b0; c_addr = 32'd0; c_wdata = 32'd0; c_wstrb = 4'd0;
    d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0012_3400;
    d_wdata = 32'hD0C0_1234; d_wstrb = 4'hF;

    // Assert both raw resets after all request inputs are valid. The request is
    // intentionally not withdrawn at any point in this sequence.
    #1;
    core_rst_n = 1'b0;
    axi_rst_n  = 1'b0;
    repeat (3) begin
      @(posedge core_clk); #1;
      expect_dma_quiet("both raw resets asserted");
    end

    // Deassert the AXI raw reset first. rst_comb_n remains low because the core
    // raw reset is still asserted, so no core-side state may start.
    @(negedge axi_clk); axi_rst_n = 1'b1;
    repeat (2) begin
      @(posedge core_clk); #1;
      expect_dma_quiet("AXI raw reset released while core raw reset remains low");
    end

    // Deassert core raw reset.  This is the bug window: a raw-reset-based
    // dma_sel would assert nb_dma_req immediately, before the two-flop core
    // reset bridge has released ven_l1d/northbridge.
    @(negedge core_clk); core_rst_n = 1'b1;
    #1;
    expect_dma_quiet("immediately after raw core reset deassertion");

    // Do not assume a fixed number of clock cycles: inspect every core edge up
    // to a small bound and require a quiet DMA seam for all still-reset cycles.
    pre_sync_edges = 0;
    while (dut.core_rst_sync_n !== 1'b1 && pre_sync_edges < 4) begin
      @(posedge core_clk); #1;
      if (dut.core_rst_sync_n !== 1'b1) begin
        expect_dma_quiet($sformatf("core reset synchronizer latency edge %0d", pre_sync_edges));
        pre_sync_edges++;
      end
    end
    if (dut.core_rst_sync_n !== 1'b1) begin
      fail("core_rst_sync_n did not release within four core clocks");
    end else begin
      // At the release boundary the still-held request may select immediately,
      // but has not yet had a core clock to become registered in-flight.
      if (dut.dma_lock_rst_n !== 1'b1)
        fail("dma_lock_rst_n did not follow the released core reset bridge");
      if (dut.nb_dma_req !== 1'b1)
        fail("held DMA request did not select after core reset bridge release");
      if (dut.dma_inflight !== 1'b0)
        fail("dma_inflight was not reset at the first legal select boundary");
      if (dut.nb_dma_we !== d_we || dut.nb_dma_addr !== d_addr ||
          dut.nb_dma_wdata !== d_wdata || dut.nb_dma_wstrb !== d_wstrb)
        fail("selected DMA payload does not match the held requester payload");

      // No-L2 ties nb_dma_ack low. The next core clock must take ownership,
      // proving a request held through reset can start once the fabric exists.
      @(posedge core_clk); #1;
      if (dut.dma_inflight !== 1'b1)
        fail("held DMA request did not latch dma_inflight after legal select");
      if (dut.nb_dma_req !== 1'b1)
        fail("nb_dma_req withdrew after legal select without an acknowledge");
    end

    // The reset bridge is coupled: an AXI-only raw reset assertion must
    // asynchronously reassert the core-side DMA reset even though core_rst_n
    // is still high. The held request must become invisible again immediately.
    @(negedge axi_clk); axi_rst_n = 1'b0;
    #1;
    if (core_rst_n !== 1'b1)
      fail("test setup lost core raw reset while asserting AXI-only reset");
    expect_dma_quiet("asymmetric AXI raw reset assertion");

    if (fails == 0)
      $display("L1AXICDCDMARESET-GATE-OK (held DMA request waits for core CDC reset release)");
    else
      $display("L1AXICDCDMARESET-GATE-FAIL (%0d error(s))", fails);
    $finish;
  end

  initial begin
    #1000;
    $display("L1AXICDCDMARESET-GATE-FAIL (timeout)");
    $finish;
  end
endmodule : tb_l1axi_cdc_dma_reset
