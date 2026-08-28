// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_lock.sv — REVIEW1_Aug3 R2-H08: locked-RMW OWNERSHIP of the
// local DMA requester on the L1/AXI path, plus DMA IN-FLIGHT ownership at the
// same seam.
//
// The pin-level biu_p5 path holds LOCK# across a locked read-modify-write; the
// L1/AXI path had no equivalent, so a DMA requester could interleave a write
// between the locked read and the locked write (a lost update). The fix is
// arbitration ownership in ventium_l1_axi: once a locked READ is acked,
// lock_owned holds the DMA requester off (nb_dma_req forced low) until the
// locked WRITE completes, the sequence aborts (any unlocked core request --
// e.g. fault delivery after the read), or reset.
//
// The reservation gates NEW selections only. A DMA request the seam already
// forwarded is an accepted transaction: dma_inflight holds nb_dma_req and the
// latched payload stable until the downstream ack (or reset, the defined
// abort), and a locked read arriving mid-flight is held out of the L1 until
// the drain, so no DMA completion can land inside the RMW window.
//
// In this checkout's no-L2 configuration the DMA path downstream is tied off
// (nb_dma_ack constant 0), so the TB plays the downstream arbiter with
// force/release on dut.nb_dma_ack, and the observables are the REQUEST
// FORWARD itself (dut.nb_dma_req + payload), the ownership registers
// (dut.lock_owned / dut.dma_inflight), and the core ack timing -- exactly the
// points the fix drives. End-to-end atomic completion needs the
// northbridge's live DMA path (L2 restoration).
//
// Cases:
//   A  control: with no lock, a DMA request forwards IMMEDIATELY, holds
//      req+payload stable (against requester-input perturbation) until the
//      modeled ack, then clears
//   A2 a same-cycle (combinational) downstream ack completes without the
//      ownership latch -- no second-cycle ghost
//   B  locked read acked -> lock_owned=1; a DMA write requested on every cycle
//      of the window must NEVER forward while the window is open
//   C  the locked write completes -> ownership releases -> the pending DMA
//      request forwards (and drains)
//   C2 DMA forwarded first, locked read asserted mid-flight: the in-flight
//      request is NOT withdrawn, the locked read acks only after the drain,
//      and no NEW DMA grant lands before the locked write completes
//   G  simultaneous first-cycle DMA + locked read: the LOCK wins the new
//      selection (documented priority); the read is not stalled; the DMA
//      forwards after the window
//   D  abort: locked read, then an UNLOCKED core request (fault-delivery
//      traffic is never lock-marked) -> ownership releases, DMA forwards
//      (the unlocked request itself completes normally -- the hold must not
//      touch the core's own path)
//   E  abort: locked read, then RESET -> ownership releases; also reset
//      MID-FLIGHT clears a forwarded-but-unacked DMA request

module tb_l1axi_lock;
  logic ic_nocache_unused;
  localparam int ADDR_W = 40;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        c_req=0, c_we=0, c_lock=0;
  logic [31:0] c_addr=0, c_wdata=0; logic [3:0] c_wstrb=0;
  logic [31:0] c_rdata; logic c_ack, bus_err;
  logic        smm_active = 0;
  logic        d_req=0, d_we=0; logic [31:0] d_addr=0, d_wdata=0; logic [3:0] d_wstrb=0;
  logic [31:0] d_rdata; logic d_ack;

  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize;
  logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot;
  logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen; logic [2:0] arsize;
  logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot;
  logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'h0FFF_FFFF),
                   .WATCHDOG(1024)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b1), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(smm_active),
      .smbase(32'h0003_0000), .smm_flush_o(), .core_lock(c_lock),
      .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
      .dma_req(d_req), .dma_we(d_we), .dma_addr(d_addr), .dma_wdata(d_wdata),
      .dma_wstrb(d_wstrb), .dma_rdata(d_rdata), .dma_ack(d_ack),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
      .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  axi_slave_bfm #(.ADDR_W(ADDR_W)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready),
      .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
      .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready),
      .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

  int fails = 0;

  // one core access; lock = the LOCK prefix marker. Waits for the ack.
  task automatic core_acc(input logic [31:0] a, input logic wr, input logic lk);
    int guard;
    begin
      @(negedge clk);
      c_addr = a; c_wdata = 32'hA5A5_0001; c_wstrb = 4'b1111;
      c_we = wr; c_lock = lk; c_req = 1'b1;
      guard = 0;
      while (guard < 400 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 400) begin
        $display("  FAIL core access %08h (wr=%0b lock=%0b) NEVER ACKED", a, wr, lk);
        fails++;
      end
      @(negedge clk); c_req = 1'b0; c_we = 1'b0; c_lock = 1'b0; c_wstrb = 4'd0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Downstream ack model. In this no-L2 checkout the northbridge consumer is
  // absent (nb_dma_ack is tied 0 inside the DUT), so the TB plays the
  // downstream arbiter with force/release: it observes the forwarded request
  // for `hold` clocks -- nb_dma_req AND its payload must stay stable the
  // whole time, even as the requester's own d_* inputs are perturbed -- then
  // acks for exactly one clock. The requester drops d_req at the ack edge,
  // as req/ack requires.
  task automatic dma_drain(input int hold, input string tag);
    logic        p_we; logic [31:0] p_addr, p_wdata; logic [3:0] p_wstrb;
    begin
      p_we = dut.nb_dma_we; p_addr = dut.nb_dma_addr;
      p_wdata = dut.nb_dma_wdata; p_wstrb = dut.nb_dma_wstrb;
      for (int k = 0; k < hold; k++) begin
        @(posedge clk); #1;
        if (dut.nb_dma_req !== 1'b1) begin
          $display("  FAIL %s: forwarded DMA request WITHDRAWN %0d clock(s) before its ack", tag, hold-k);
          fails++;
          k = hold;
        end else if (dut.nb_dma_we !== p_we || dut.nb_dma_addr !== p_addr ||
                     dut.nb_dma_wdata !== p_wdata || dut.nb_dma_wstrb !== p_wstrb) begin
          $display("  FAIL %s: forwarded DMA payload changed before its ack", tag);
          fails++;
          k = hold;
        end
      end
      force dut.nb_dma_ack = 1'b1;
      @(posedge clk); #1;
      release dut.nb_dma_ack;
      if (dut.dma_inflight !== 1'b0) begin
        $display("  FAIL %s: dma_inflight did not clear at the ack", tag);
        fails++;
      end
      @(negedge clk); d_req = 1'b0;
      @(posedge clk); #1;
      if (dut.nb_dma_req !== 1'b0) begin
        $display("  FAIL %s: nb_dma_req did not drop after the ack + req drop", tag);
        fails++;
      end
      repeat (1) @(posedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

    $display("== locked-RMW ownership + DMA in-flight ownership of the local DMA port ==");

    // A -- CONTROL: no lock -> the DMA request forwards immediately, holds
    // stable until the ack, and clears. Perturb the requester's inputs while
    // it waits: the forwarded payload must not follow them.
    @(negedge clk); d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0002_0000; d_wdata = 32'h1111_2222; d_wstrb = 4'hF;
    @(posedge clk); #1;
    if (dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL control: an unlocked DMA request did not forward (lock logic");
      $display("       is holding the port with no lock in flight)");
      fails++;
    end else $display("  ok   control: DMA forwards with no lock in flight");
    @(negedge clk); d_addr = 32'hDEAD_BEEF; d_wdata = 32'h0BAD_0BAD; d_wstrb = 4'h1; d_we = 1'b0;
    dma_drain(3, "control");
    $display("  ok   control: forwarded request held req+payload stable for 3 clocks, acked, cleared");

    // A2 -- same-cycle ack: a downstream that acks combinationally completes
    // the transfer WITHOUT the ownership latch, so nothing ghosts a second
    // cycle.
    @(negedge clk); d_req = 1'b1; d_we = 1'b0; d_addr = 32'h0002_2000;
    force dut.nb_dma_ack = 1'b1;
    @(posedge clk); #1;
    release dut.nb_dma_ack;
    @(negedge clk); d_req = 1'b0;
    @(posedge clk); #1;
    if (dut.dma_inflight !== 1'b0 || dut.nb_dma_req !== 1'b0) begin
      $display("  FAIL same-cycle ack: dma_inflight latched (a completed transfer replayed)");
      fails++;
    end else $display("  ok   same-cycle ack completes without latching ownership");

    // B -- the locked read opens the window; DMA must not forward inside it.
    core_acc(32'h0001_0000, 1'b0, 1'b1);          // locked read
    @(posedge clk); #1;
    if (dut.lock_owned !== 1'b1) begin
      $display("  FAIL lock_owned not set after the locked read's ack");
      fails++;
    end else $display("  ok   locked read took ownership");
    // the adversary: a DMA write requested on EVERY cycle of the window
    @(negedge clk); d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0001_0000; d_wdata = 32'hBAD0_0BAD;
    begin
      int leaked; leaked = 0;
      for (int i = 0; i < 24; i++) begin
        @(posedge clk); #1;
        if (dut.nb_dma_req === 1'b1) leaked++;
      end
      if (leaked != 0) begin
        $display("  FAIL a DMA write forwarded on %0d cycle(s) INSIDE the locked window", leaked);
        fails++;
      end else $display("  ok   no DMA forward on any of 24 window cycles (adversarial write)");
    end

    // C -- the locked write completes: ownership releases, the pending DMA forwards.
    core_acc(32'h0001_0000, 1'b1, 1'b1);          // locked write (d_req still high)
    @(posedge clk); #1;
    if (dut.lock_owned !== 1'b0) begin
      $display("  FAIL lock_owned still set after the locked write's ack");
      fails++;
    end else if (dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL the pending DMA request did not forward after release");
      fails++;
    end else $display("  ok   locked write released ownership; pending DMA forwards");
    dma_drain(2, "post-window");

    // C2 -- IN-FLIGHT vs LOCK: the DMA request is forwarded FIRST, then the
    // locked read arrives while the beat still owns the seam. The forwarded
    // request must NOT be withdrawn (req+payload stable until the ack), the
    // locked read must NOT ack before the drain, and after the drain the
    // read completes and the window holds against new DMA requests.
    @(negedge clk); d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0001_1000; d_wdata = 32'hBAD0_0BAD; d_wstrb = 4'hF;
    @(posedge clk); #1;
    if (dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL in-flight setup: the DMA request did not forward before the lock");
      fails++;
    end
    @(negedge clk);
    c_addr = 32'h0001_1000; c_wdata = 32'hA5A5_0002; c_wstrb = 4'b1111;
    c_we = 1'b0; c_lock = 1'b1; c_req = 1'b1;   // locked read, DMA in flight
    repeat (4) begin
      @(posedge clk); #1;
      if (dut.nb_dma_req !== 1'b1) begin
        $display("  FAIL the lock reservation WITHDREW the in-flight DMA request");
        fails++;
      end
      if (dut.nb_dma_addr !== 32'h0001_1000 || dut.nb_dma_wdata !== 32'hBAD0_0BAD) begin
        $display("  FAIL the in-flight DMA payload moved when the lock asserted");
        fails++;
      end
      if (c_ack === 1'b1) begin
        $display("  FAIL the locked read acked BEFORE the in-flight DMA drained");
        fails++;
      end
    end
    force dut.nb_dma_ack = 1'b1;
    @(posedge clk); #1;
    release dut.nb_dma_ack;
    @(negedge clk); d_req = 1'b0;
    // now the drain has happened: the stalled locked read must complete.
    begin
      int guard; guard = 0;
      while (guard < 400 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 400) begin
        $display("  FAIL the locked read never acked after the DMA drain");
        fails++;
      end else $display("  ok   in-flight DMA held req+payload; locked read acked only after the drain");
    end
    @(negedge clk); c_req = 1'b0; c_we = 1'b0; c_lock = 1'b0; c_wstrb = 4'd0;
    repeat (2) @(posedge clk);
    // the same DMA re-requested inside the window must wait for the locked write
    @(negedge clk); d_req = 1'b1;
    repeat (4) begin
      @(posedge clk); #1;
      if (dut.nb_dma_req !== 1'b0) begin
        $display("  FAIL a NEW DMA request forwarded inside the post-drain locked window");
        fails++;
      end
    end
    core_acc(32'h0001_1000, 1'b1, 1'b1);          // locked write (d_req still high)
    @(posedge clk); #1;
    if (dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL the post-window DMA did not forward after the locked write");
      fails++;
    end else $display("  ok   no DMA grant between locked-read ownership and locked-write completion");
    dma_drain(2, "post-drain-window");

    // G -- simultaneous first-cycle DMA + locked read: the LOCK wins the new
    // selection (documented priority), so nothing enters flight and the read
    // is not stalled; the DMA forwards only after the window.
    @(negedge clk);
    d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0001_2000; d_wdata = 32'hBAD0_2222; d_wstrb = 4'hF;
    c_addr = 32'h0001_2000; c_wdata = 32'hA5A5_0003; c_wstrb = 4'b1111;
    c_we = 1'b0; c_lock = 1'b1; c_req = 1'b1;
    @(posedge clk); #1;
    if (dut.nb_dma_req !== 1'b0 || dut.dma_inflight !== 1'b0) begin
      $display("  FAIL priority: a DMA request simultaneous with a locked read was selected");
      fails++;
    end else $display("  ok   priority: the locked read wins a simultaneous DMA selection");
    begin
      int guard; guard = 0;
      while (guard < 400 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 400) begin
        $display("  FAIL priority: the simultaneous locked read never acked (nothing was in flight)");
        fails++;
      end
    end
    @(negedge clk); c_req = 1'b0; c_we = 1'b0; c_lock = 1'b0; c_wstrb = 4'd0;
    repeat (2) @(posedge clk);
    core_acc(32'h0001_2000, 1'b1, 1'b1);          // locked write releases
    @(posedge clk); #1;
    if (dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL priority: the simultaneous DMA did not forward after the window");
      fails++;
    end
    dma_drain(2, "priority");

    // D -- ABORT by an unlocked core request (the fault-delivery shape): a locked
    // read, then ordinary core traffic must release the port -- and complete.
    core_acc(32'h0001_0040, 1'b0, 1'b1);          // locked read
    @(negedge clk); d_req = 1'b1;
    core_acc(32'h0002_0040, 1'b0, 1'b0);          // UNLOCKED core read (must also ack)
    @(posedge clk); #1;
    if (dut.lock_owned !== 1'b0 || dut.nb_dma_req !== 1'b1) begin
      $display("  FAIL abort-by-unlocked-request did not release ownership");
      fails++;
    end else $display("  ok   an unlocked core request releases ownership (abort path)");
    dma_drain(2, "abort");

    // E -- ABORT by reset (also covers reset MID-FLIGHT: the defined abort
    // response -- a reset may drop a forwarded request).
    core_acc(32'h0001_0080, 1'b0, 1'b1);          // locked read
    @(posedge clk); #1;
    if (dut.lock_owned !== 1'b1) begin
      $display("  FAIL setup for the reset case: ownership not taken");
      fails++;
    end
    rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1; repeat (3) @(posedge clk);
    if (dut.lock_owned !== 1'b0) begin
      $display("  FAIL reset did not release ownership");
      fails++;
    end else $display("  ok   reset releases ownership");
    // mid-flight reset: forward, do NOT ack, reset -> the seam must clear.
    @(negedge clk); d_req = 1'b1; d_we = 1'b1; d_addr = 32'h0002_4000; d_wdata = 32'hBAD0_4444; d_wstrb = 4'hF;
    repeat (2) @(posedge clk);
    rst_n = 1'b0; repeat (3) @(posedge clk);
    @(negedge clk); d_req = 1'b0;
    rst_n = 1'b1; repeat (3) @(posedge clk);
    if (dut.dma_inflight !== 1'b0 || dut.nb_dma_req !== 1'b0) begin
      $display("  FAIL reset mid-flight did not clear the DMA ownership");
      fails++;
    end else $display("  ok   reset mid-flight clears the forwarded request (defined abort)");

    if (fails == 0) $display("L1AXILOCK-GATE-OK (locked window holds the DMA port; in-flight DMA is never withdrawn, drains before the lock; completion/abort/reset release)");
    else            $display("L1AXILOCK-GATE-FAIL (%0d)", fails);
    $finish;
  end
endmodule
