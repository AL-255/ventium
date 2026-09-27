// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_smram.sv — REVIEW1_Aug2 H-08: the BUILDABLE (EN_L2=0) path must
// deny non-SMM access to the SMRAM aperture.
//
// SMM's whole security model is that its RAM is invisible outside SMM: the handler's
// code and the saved CPU state live at A0000-BFFFF, and if ordinary code can read or
// write them, SMM provides no isolation at all. The EN_L2=1 branch enforces this via
// ven_cachemap, but that source is on an unmerged branch -- and the branch that BUILDS
// consumed smm_active nowhere.
//
// REVIEW2_aug2 C-08: this gate ORIGINALLY drove 0xA0000 -- the 82437FX video aperture,
// which is what the guard named. But this core's SMBASE is 0x30000, so SMM actually
// lives at SMBASE+0x8000 = 0x38000 with the save map at 0x3FE00..0x3FFFC. The guard
// protected a range the core does not use, and the test agreed with it. Both now name
// the real window, and the case addresses below are inside it.
//
// 82437FX SMRAM (0x72): bit 3 = DEN, bit 6 = DOPEN. DRAM-backed iff DEN && (DOPEN ||
// in SMM). This gate instantiates with DEN=1, DOPEN=0 and drives four cases:
//
//   A  SMM      write to 0xA0000 -> must REACH memory (else SMM itself is broken)
//   B  non-SMM  write to 0xA0000 -> must NOT reach memory (the finding)
//   C  non-SMM  read  of 0xA0000 -> must NOT return the SMM contents
//   D  non-SMM  write to 0x20000 -> must REACH memory (the control: a check that
//                                   denied everything would pass A..C and be useless)
//
// Every case must also ACK. A denied access that never completes hangs the core, which
// is how the H-07 bypass attempt failed; "denied" must mean completed-as-unbacked.

module tb_l1axi_smram;
  logic ic_nocache_unused;   // REVIEW2_aug2 H-13
  localparam int ADDR_W = 40;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        c_req=0, c_we=0; logic [31:0] c_addr=0, c_wdata=0; logic [3:0] c_wstrb=0;
  logic [31:0] c_rdata; logic c_ack, bus_err;
  logic        smm_active = 0;

  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize;
  logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot;
  logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen; logic [2:0] arsize;
  logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot;
  logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  // NB_SMRAM = 8'h08 -> DEN=1 (bit 3), DOPEN=0 (bit 6): SMM space enabled and CLOSED.
  // golden_l1 keeps the L1 out of the way so every core request reaches the seam.
  // REVIEW_Aug4 A4-H04: golden_l1/smbase are TB-DRIVEN RUNTIME signals now -- the
  // H-08 phases below run with golden_l1=1 (L1 transparent, as before); the new
  // residency-attack phases drop it to 0 so lines stay resident between
  // transactions. smbase is relocatable for the phase-3 case, and smm_flush_o is
  // observed directly (the SMM-exit / relocation flush pulse).
  logic        golden_r = 1'b1;
  logic [31:0] smbase_r = 32'h0003_0000;
  logic        smm_flush_w;
  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'h0FFF_FFFF),
                   .WATCHDOG(1024), .NB_SMRAM(8'h08)) dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .core_next_req(1'b0), .core_next_commit(1'b0),
      .core_next_addr(32'd0), .core_next_wstrb(4'd0), .core_next_ready(),
`endif

      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(golden_r), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(smm_active),
      .smbase(smbase_r), .smm_flush_o(smm_flush_w), /* C-10 */ .core_lock(1'b0), .core_lock_hold(1'b0),   // REVIEW2_aug2 C-08: the core's ACTUAL default SMBASE
      .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      // REVIEW2_aug2 H-13: the I-side memory type. Not exercised by this
      // memory-subsystem gate; connected so the build stays warning-clean.
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
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

  // ---- A4-H04 observables (independent of the BFM's AXI_BFM_MON define, which
  // this gate's build does not set): count AR handshakes and smm_flush_o pulses
  // directly on the bus. A refill after an SMM-exit flush is the residency
  // observable: a line the flush invalidated must be re-fetched from backing. --
  logic [31:0] ar_seen      = 32'd0;
  logic [31:0] aw_seen      = 32'd0;
  logic [31:0] flush_pulses = 32'd0;
  always @(posedge clk) if (arvalid && arready) ar_seen      <= ar_seen + 32'd1;
  always @(posedge clk) if (awvalid && awready) aw_seen      <= aw_seen + 32'd1;
  always @(posedge clk) if (smm_flush_w)        flush_pulses <= flush_pulses + 32'd1;
  logic [31:0] ar0, p0, aw0;

  task automatic do_write(input logic [31:0] a, input logic [31:0] d, input bit smm);
    do_write_be(a, d, 4'b1111, smm);
  endtask

  // strobe'd write: wdata/wstrb are lane-0-justified at the byte address (the
  // compact form the core drives: 0001=byte, 0011=word, 1111=dword).
  task automatic do_write_be(input logic [31:0] a, input logic [31:0] d, input logic [3:0] be, input bit smm);
    int guard;
    begin
      @(negedge clk);
      smm_active = smm;
      c_addr = a; c_wdata = d; c_wstrb = be; c_we = 1'b1; c_req = 1'b1;
      guard = 0;
      while (guard < 300 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 300) begin
        $display("  FAIL write %08h strb %b (smm=%0b) NEVER ACKED -- a denied access must", a, be, smm);
        $display("       complete as an unbacked aperture, not hang the requester");
        fails++;
      end
      @(negedge clk); c_req = 1'b0; c_we = 1'b0; c_wstrb = 4'd0;
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic do_read(input logic [31:0] a, input bit smm, output logic [31:0] v);
    int guard;
    begin
      @(negedge clk);
      smm_active = smm;
      c_addr = a; c_we = 1'b0; c_wstrb = 4'd0; c_req = 1'b1;
      guard = 0; v = 32'hDEAD_DEAD;
      while (guard < 300 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 300) begin
        $display("  FAIL read %08h (smm=%0b) NEVER ACKED", a, smm);
        fails++;
      end else v = c_rdata;
      @(negedge clk); c_req = 1'b0;
      repeat (3) @(posedge clk);
    end
  endtask

  // strobe'd read: the compact size strobes (1=byte, 3=word, F=dword) that let
  // the subsystem classify the access by its REAL byte extent.
  task automatic do_read_be(input logic [31:0] a, input logic [3:0] be, input bit smm, output logic [31:0] v);
    int guard;
    begin
      @(negedge clk);
      smm_active = smm;
      c_addr = a; c_we = 1'b0; c_wstrb = be; c_req = 1'b1;
      guard = 0; v = 32'hDEAD_DEAD;
      while (guard < 300 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 300) begin
        $display("  FAIL read %08h strb %b (smm=%0b) NEVER ACKED", a, be, smm);
        fails++;
      end else v = c_rdata;
      @(negedge clk); c_req = 1'b0; c_wstrb = 4'd0;
      repeat (3) @(posedge clk);
    end
  endtask

  logic [31:0] rv;

  initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

    $display("== REVIEW1_Aug2 H-08: SMRAM must be invisible outside SMM ==");
    $display("   NB_SMRAM=0x08 -> DEN=1, DOPEN=0; SMBASE=0x30000, window 0x30000-0x3FFFF");

    // A — SMM writes the secret, then reads it back from SMM. This must work, or the
    //     check has simply broken SMM instead of protecting it.
    do_write(32'h0003_8000, 32'h5EC2_E7A1, 1'b1);
    do_read (32'h0003_8000, 1'b1, rv);
    if (rv !== 32'h5EC2_E7A1) begin
      $display("  FAIL SMM cannot see its own SMRAM: read %08h, want 5ec2e7a1", rv);
      fails++;
    end else $display("  ok   SMM reads back its own SMRAM (%08h)", rv);

    // B/C — THE FINDING: non-SMM must neither read nor overwrite it.
    do_write(32'h0003_8000, 32'hBAD0_BAD0, 1'b0);
    do_read (32'h0003_8000, 1'b1, rv);          // re-read FROM SMM to see the truth
    if (rv !== 32'h5EC2_E7A1) begin
      $display("  FAIL a NON-SMM write reached SMRAM: it now holds %08h", rv);
      $display("       Ordinary code can rewrite the SMM handler and its saved state.");
      fails++;
    end else $display("  ok   a non-SMM write did NOT reach SMRAM");

    // RE-SEED from SMM before the read check. Without this, C is not independent of
    // B: in a build where B's write got through, the secret is already clobbered, so
    // the non-SMM read trivially differs from it and C "passes" for the wrong reason.
    // Measured on the reverted build -- C reported ok while SMRAM was wide open.
    do_write(32'h0003_8000, 32'h5EC2_E7A1, 1'b1);
    do_read (32'h0003_8000, 1'b0, rv);
    if (rv === 32'h5EC2_E7A1) begin
      $display("  FAIL a NON-SMM read returned the SMRAM contents (%08h)", rv);
      fails++;
    end else $display("  ok   a non-SMM read did not observe SMRAM (%08h)", rv);

    // D — CONTROL: ordinary memory outside the aperture must still work non-SMM.
    do_write(32'h0002_0000, 32'h1234_5678, 1'b0);
    do_read (32'h0002_0000, 1'b0, rv);
    if (rv !== 32'h1234_5678) begin
      $display("  FAIL ordinary non-SMM memory broke: read %08h, want 12345678", rv);
      fails++;
    end else $display("  ok   ordinary non-SMM memory still works (control)");

    // ======================================================================
    // REVIEW_Aug4 A4-H04 — the SMRAM RESIDENCY ATTACK (golden_l1=0).
    //
    // With golden_l1=1 (above) the L1 is flushed after every transaction, so
    // residency is meaningless; with golden_l1=0 lines stay resident. The
    // mechanism under test (rtl/mem/ventium_l1_axi.sv): (a) core_smram_deny, a
    // PRE-LOOKUP deny at the core seam -- a non-SMM access to
    // [smbase,smbase+0xFFFF] never enters ven_l1d at all (acked locally,
    // rdata=0, qualified with core_req); (b) smm_flush, a full I/D invalidation
    // on the SMM-exit edge and on SMBASE relocation (drives ven_l1d flush_all
    // and the core-side smm_flush_o, observed here directly). ven_l1d is
    // WRITE-THROUGH, so SMM writes reach the backing immediately and the pure
    // invalidate-on-exit loses no data.
    // ======================================================================
    $display("== REVIEW_Aug4 A4-H04: SMRAM residency attack (golden_l1=0) ==");
    golden_r = 1'b0;
    repeat (4) @(posedge clk);

    // ---- Phase 1: D-line residency ------------------------------------------
    // In SMM: write + read 0x38000 -> its line is resident. Exit WITHOUT any
    // software flush: the exit edge must flush (phase 2's pulse check) and the
    // attack must see nothing, through the seam deny and/or the invalidation.
    do_write(32'h0003_8000, 32'h5EC2_E7A1, 1'b1);
    do_read (32'h0003_8000, 1'b1, rv);
    if (rv !== 32'h5EC2_E7A1) begin
      $display("  FAIL [A4H04-1] SMM cannot read back its own write (%08h)", rv);
      fails++;
    end

    p0 = flush_pulses;
    do_read (32'h0003_8000, 1'b0, rv);      // the SMM-exit edge lives in this call
    if (flush_pulses !== p0 + 32'd1) begin
      $display("  FAIL [A4H04-2] smm_flush_o pulsed %0d times on SMM exit (want exactly 1)",
               flush_pulses - p0);
      fails++;
    end else $display("  ok   smm_flush_o pulsed exactly once on the SMM-exit edge");
    if (rv !== 32'h0000_0000) begin
      $display("  FAIL [A4H04-1] non-SMM read of a previously-resident line LEAKED SMRAM (%08h)", rv);
      fails++;
    end else $display("  ok   non-SMM read of a previously-resident SMRAM line returns 0 (no leak)");

    do_write(32'h0003_8000, 32'hBAD0_BAD0, 1'b0);   // attack write: must not land

    ar0 = ar_seen;
    do_read (32'h0003_8000, 1'b1, rv);      // re-enter SMM
    if (rv !== 32'h5EC2_E7A1) begin
      $display("  FAIL [A4H04-1] SMRAM bytes clobbered by the denied attack (read %08h)", rv);
      fails++;
    end else $display("  ok   SMRAM bytes intact across the denied non-SMM write (%08h)", rv);
    if (ar_seen - ar0 < 1) begin
      $display("  FAIL [A4H04-2] the re-entered SMM read HIT (%0d ARs) -- the resident", ar_seen - ar0);
      $display("       line SURVIVED the exit flush (residency attack possible)");
      fails++;
    end else $display("  ok   resident line invalidated on exit: re-entered SMM read refilled (%0d AR)", ar_seen - ar0);

    // ---- Phase 2: the invalidation + pulse, isolated on a KNOWN-resident line --
    // Re-resident the line in SMM (this read hits), exit again, and show the
    // same two observables once more with no prior-phase history in between.
    do_read (32'h0003_8000, 1'b1, rv);      // line resident again (hit)
    p0 = flush_pulses;
    do_read (32'h0003_8000, 1'b0, rv);      // second exit edge + seam deny
    if (flush_pulses !== p0 + 32'd1) begin
      $display("  FAIL [A4H04-2] second exit: smm_flush_o pulsed %0d times (want exactly 1)",
               flush_pulses - p0);
      fails++;
    end
    ar0 = ar_seen;
    do_read (32'h0003_8000, 1'b1, rv);      // re-enter: must MISS and refill
    if (ar_seen - ar0 < 1) begin
      $display("  FAIL [A4H04-2] second exit: the known-resident line still HIT on re-entry");
      fails++;
    end else $display("  ok   exit invalidation + flush pulse confirmed on a known-resident line");

    // ---- Phase 3: SMBASE relocation -----------------------------------------
    // In SMM, move the window 0x30000 -> 0x80000: the flush must fire, the OLD
    // window turns back into ordinary RAM (for SMM and non-SMM alike), and the
    // NEW window is protected once SMM exits.
    @(negedge clk);
    smm_active = 1'b1;                      // be in SMM (no edge if already)
    smbase_r   = 32'h0008_0000;             // relocate
    p0 = flush_pulses;
    repeat (4) @(posedge clk);
    if (flush_pulses !== p0 + 32'd1) begin
      $display("  FAIL [A4H04-3] smm_flush_o pulsed %0d times on SMBASE relocation (want exactly 1)",
               flush_pulses - p0);
      fails++;
    end else $display("  ok   smm_flush_o pulsed exactly once on SMBASE relocation");

    do_write(32'h0008_8000, 32'h5AFE_0001, 1'b1);   // NEW window, in SMM
    do_write(32'h0003_8000, 32'hAAAA_0001, 1'b1);   // OLD window: ordinary rules now
    do_read (32'h0003_8000, 1'b1, rv);
    if (rv !== 32'hAAAA_0001) begin
      $display("  FAIL [A4H04-3] OLD window not ordinary RAM in SMM after relocation (%08h)", rv);
      fails++;
    end else $display("  ok   OLD window follows ordinary memory rules after relocation");

    do_read (32'h0008_8000, 1'b0, rv);      // exit; attack the NEW window
    if (rv !== 32'h0000_0000) begin
      $display("  FAIL [A4H04-3] NEW window leaked after exit (%08h)", rv);
      fails++;
    end else $display("  ok   NEW window protected after exit (non-SMM read returns 0)");
    do_write(32'h0008_8000, 32'hBAD0_BAD0, 1'b0);
    do_read (32'h0003_8000, 1'b0, rv);      // OLD window: unprotected now
    if (rv !== 32'hAAAA_0001) begin
      $display("  FAIL [A4H04-3] OLD window still denied to non-SMM after relocation (%08h)", rv);
      fails++;
    end else $display("  ok   OLD window is ordinary memory to non-SMM after relocation");
    do_read (32'h0008_8000, 1'b1, rv);      // re-enter: NEW window intact
    if (rv !== 32'h5AFE_0001) begin
      $display("  FAIL [A4H04-3] NEW-window SMRAM clobbered by the denied attack (%08h)", rv);
      fails++;
    end else $display("  ok   NEW-window SMRAM intact across the denied attack");

    @(negedge clk);
    smbase_r = 32'h0003_0000;               // relocate back (phase 4 needs 0x30000)
    p0 = flush_pulses;
    repeat (4) @(posedge clk);
    if (flush_pulses !== p0 + 32'd1) begin
      $display("  FAIL [A4H04-3] no flush on the relocation back (%0d pulses)", flush_pulses - p0);
      fails++;
    end else $display("  ok   smm_flush_o pulsed on the relocation back to 0x30000");

    // ---- Phase 4: byte extents at the window edge (smbase = 0x30000) --------
    // The deny's extent is [smbase, smbase+0xFFFF] against core_d_last: a dword
    // at smbase-4 ends at smbase-1 (fully outside, ordinary rules); a dword at
    // smbase-2 ends INSIDE (denied as a whole, like the SMRAM-window straddle
    // guard C-08 added for the backing seam).
    do_write(32'h0003_0000, 32'h5A5A_0001, 1'b1);   // seed the window base
    do_write(32'h0002_FFFC, 32'h1234_5678, 1'b0);   // fully below: ordinary write
    do_read (32'h0002_FFFC, 1'b0, rv);
    if (rv !== 32'h1234_5678) begin
      $display("  FAIL [A4H04-4] smbase-4 access broke (%08h, want 12345678)", rv);
      fails++;
    end else $display("  ok   smbase-4 dword (fully outside) works normally");
    do_read (32'h0002_FFFE, 1'b0, rv);
    if (rv !== 32'h0000_0000) begin
      $display("  FAIL [A4H04-4] smbase-2 straddle read NOT denied (%08h)", rv);
      fails++;
    end else $display("  ok   smbase-2 straddle (last byte inside) is denied as a whole");
    do_write(32'h0002_FFFE, 32'hDEAD_BEEF, 1'b0);   // straddling write attack
    do_read (32'h0003_0000, 1'b1, rv);
    if (rv !== 32'h5A5A_0001) begin
      $display("  FAIL [A4H04-4] the straddling write touched the window (%08h)", rv);
      fails++;
    end else $display("  ok   straddling write left the window bytes intact");

    // ---- Phase 5: byte/word endpoints at BOTH window edges ------------------
    // The closed-window deny is extent-aware: an access is denied iff its first
    // byte is at/below the window top AND its last byte is at/above the window
    // base. A byte/word access just below smbase touches no window byte and
    // must follow ordinary memory rules -- classifying it with a 4-byte window
    // would deny it. The compact size strobes (1/3/F) carry the real extent;
    // sub-word reads check only their own lanes of the served dword window.
    $display("== byte/word endpoints at the SMRAM window edges ==");

    // -- low edge (B = smbase = 0x30000): the below side must be ordinary ------
    // Byte/word writes just below B land on the bus and in the backing; the
    // seam classifies them by their own extent, which never reaches smbase.
    aw0 = aw_seen;
    do_write_be(32'h0002_FFFF, 32'h0000_00AA, 4'b0001, 1'b0);   // byte 3 of 0x2FFFC
    if (aw_seen - aw0 !== 32'd1) begin
      $display("  FAIL byte write just below smbase: %0d AWs (want 1)", aw_seen - aw0);
      fails++;
    end
    do_read (32'h0002_FFFC, 1'b0, rv);
    if (rv !== 32'hAA34_5678) begin
      $display("  FAIL byte write just below smbase did not land (%08h, want aa345678)", rv);
      fails++;
    end else $display("  ok   byte write just below smbase lands on the bus and in backing");
    aw0 = aw_seen;
    do_write_be(32'h0002_FFFE, 32'h0000_C3C3, 4'b0011, 1'b0);
    if (aw_seen - aw0 !== 32'd1) begin
      $display("  FAIL word write just below smbase: %0d AWs (want 1)", aw_seen - aw0);
      fails++;
    end
    // -- low edge: byte/word reads ending at smbase-1 are NOT denied ------------
    do_read_be(32'h0002_FFFF, 4'b0001, 1'b0, rv);
    if (rv[7:0] !== 8'hC3) begin
      $display("  FAIL byte read ending at smbase-1 denied/misread (%08h, want ..c3)", rv);
      fails++;
    end else $display("  ok   byte read ending at smbase-1 is ordinary memory");
    do_read_be(32'h0002_FFFE, 4'b0011, 1'b0, rv);
    if (rv[15:0] !== 16'hC3C3) begin
      $display("  FAIL word read ending at smbase-1 denied/misread (%08h, want ..c3c3)", rv);
      fails++;
    end else $display("  ok   word read ending at smbase-1 is ordinary memory");

    // -- low edge: anything touching the window is denied as a whole -----------
    ar0 = ar_seen;
    do_read_be(32'h0003_0000, 4'b0001, 1'b0, rv);
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL byte read at smbase not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   byte read at smbase denied (rdata=0, no bus access)");
    ar0 = ar_seen;
    do_read_be(32'h0003_0000, 4'b0011, 1'b0, rv);
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL word read at smbase not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   word read at smbase denied (rdata=0, no bus access)");
    ar0 = ar_seen;
    do_read_be(32'h0002_FFFD, 4'b1111, 1'b0, rv);   // straddle: last byte = smbase
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL straddling dword read into the window not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   straddling dword read (last byte = smbase) denied as a whole");
    aw0 = aw_seen;
    do_write_be(32'h0003_0000, 32'h0000_0066, 4'b0001, 1'b0);   // denied byte attack
    if (aw_seen !== aw0) begin
      $display("  FAIL the denied byte write at smbase reached the bus");
      fails++;
    end
    do_read (32'h0003_0000, 1'b1, rv);
    if (rv !== 32'h5A5A_0001) begin
      $display("  FAIL the denied byte write touched the window base (%08h)", rv);
      fails++;
    end else $display("  ok   denied byte write at smbase left the window intact");
    aw0 = aw_seen;
    do_write_be(32'h0002_FFFD, 32'hDEAD_BEEF, 4'b1111, 1'b0);   // straddling attack
    if (aw_seen !== aw0) begin
      $display("  FAIL the straddling write into the window reached the bus");
      fails++;
    end
    do_read (32'h0002_FFFC, 1'b0, rv);
    if (rv !== 32'hC3C3_5678) begin
      $display("  FAIL the straddling write touched the BELOW-window bytes (%08h)", rv);
      fails++;
    end else $display("  ok   straddling write suppressed on the below-window side too");
    do_read (32'h0003_0000, 1'b1, rv);
    if (rv !== 32'h5A5A_0001) begin
      $display("  FAIL the straddling write touched the window (%08h)", rv);
      fails++;
    end

    // -- low edge, SMM (open) controls: same shapes must just work --------------
    do_read_be(32'h0002_FFFF, 4'b0001, 1'b1, rv);
    if (rv[7:0] !== 8'hC3) begin
      $display("  FAIL SMM byte read below smbase misread (%08h, want ..c3)", rv);
      fails++;
    end
    do_read_be(32'h0003_0000, 4'b0001, 1'b1, rv);
    if (rv[7:0] !== 8'h01) begin
      $display("  FAIL SMM byte read at smbase misread (%08h, want ..01)", rv);
      fails++;
    end
    do_read_be(32'h0002_FFFE, 4'b0011, 1'b1, rv);
    if (rv[15:0] !== 16'hC3C3) begin
      $display("  FAIL SMM word read below smbase misread (%08h, want ..c3c3)", rv);
      fails++;
    end else $display("  ok   SMM byte/word reads at the low edge are ordinary");

    // -- high edge (B = smbase+0x10000 = 0x40000) --------------------------------
    do_write   (32'h0003_FFFC, 32'hC0DE_0001, 1'b1);    // window top word, from SMM
    do_write   (32'h0004_0000, 32'h0DDC_0002, 1'b0);    // ordinary word above
    ar0 = ar_seen;
    do_read_be(32'h0003_FFFF, 4'b0001, 1'b0, rv);       // the last window byte
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL byte read at the window top not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   byte read at the window top is denied");
    ar0 = ar_seen;
    do_read_be(32'h0003_FFFE, 4'b0011, 1'b0, rv);       // word wholly inside
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL word read wholly inside the window not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   word read wholly inside the window is denied");
    ar0 = ar_seen;
    do_read_be(32'h0003_FFFD, 4'b1111, 1'b0, rv);       // straddle out: last=0x40000
    if (rv !== 32'h0 || ar_seen !== ar0) begin
      $display("  FAIL straddling dword read out of the window not denied (rv=%08h, %0d ARs)", rv, ar_seen - ar0);
      fails++;
    end else $display("  ok   straddling dword read (first byte inside) denied as a whole");
    do_read_be(32'h0004_0000, 4'b0001, 1'b0, rv);
    if (rv[7:0] !== 8'h02) begin
      $display("  FAIL byte read just above the window misread/denied (%08h, want ..02)", rv);
      fails++;
    end else $display("  ok   byte read just above the window is ordinary memory");
    do_read_be(32'h0004_0000, 4'b0011, 1'b0, rv);
    if (rv[15:0] !== 16'h0002) begin
      $display("  FAIL word read just above the window misread/denied (%08h, want ..0002)", rv);
      fails++;
    end
    do_read_be(32'h0004_0000, 4'b1111, 1'b0, rv);
    if (rv !== 32'h0DDC_0002) begin
      $display("  FAIL dword read just above the window misread/denied (%08h)", rv);
      fails++;
    end else $display("  ok   word/dword reads just above the window are ordinary");
    do_write_be(32'h0003_FFFF, 32'h0000_0066, 4'b0001, 1'b0);   // denied attack on top byte
    do_read (32'h0003_FFFC, 1'b1, rv);
    if (rv !== 32'hC0DE_0001) begin
      $display("  FAIL the denied byte write touched the window top (%08h)", rv);
      fails++;
    end else $display("  ok   denied byte write at the window top left it intact");
    do_write_be(32'h0003_FFFD, 32'hDEAD_BEEF, 4'b1111, 1'b0);   // straddle-out attack
    do_read (32'h0003_FFFC, 1'b1, rv);
    if (rv !== 32'hC0DE_0001) begin
      $display("  FAIL the straddle-out write touched the window top (%08h)", rv);
      fails++;
    end
    do_read (32'h0004_0000, 1'b0, rv);
    if (rv !== 32'h0DDC_0002) begin
      $display("  FAIL the straddle-out write touched the ABOVE-window bytes (%08h)", rv);
      fails++;
    end else $display("  ok   straddle-out write suppressed on both sides of the edge");
    do_write_be(32'h0004_0000, 32'h0000_0077, 4'b0001, 1'b0);   // lands above
    do_read (32'h0004_0000, 1'b0, rv);
    if (rv !== 32'h0DDC_0077) begin
      $display("  FAIL byte write just above the window did not land (%08h)", rv);
      fails++;
    end else $display("  ok   byte write just above the window lands");
    do_read_be(32'h0003_FFFF, 4'b0001, 1'b1, rv);       // SMM (open) top-byte control
    if (rv[7:0] !== 8'hC0) begin
      $display("  FAIL SMM byte read at the window top misread (%08h, want ..c0)", rv);
      fails++;
    end
    do_read_be(32'h0004_0000, 4'b0001, 1'b1, rv);
    if (rv[7:0] !== 8'h77) begin
      $display("  FAIL SMM byte read above the window misread (%08h, want ..77)", rv);
      fails++;
    end else $display("  ok   SMM byte reads at the high edge are ordinary");

    if (fails == 0) $display("L1AXISMRAM-GATE-OK (SMRAM isolated; SMM and normal memory unaffected; A4-H04 residency held)");
    else            $display("L1AXISMRAM-GATE-FAIL (%0d)", fails);
    $finish;
  end
endmodule
