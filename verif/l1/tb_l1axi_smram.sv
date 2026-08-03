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
  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'h0FFF_FFFF),
                   .WATCHDOG(1024), .NB_SMRAM(8'h08)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b1), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(smm_active),
      .smbase(32'h0003_0000), /* C-10 */ .core_lock(1'b0),   // REVIEW2_aug2 C-08: the core's ACTUAL default SMBASE
      .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      // REVIEW2_aug2 H-13: the I-side memory type. Not exercised by this
      // memory-subsystem gate; connected so the build stays warning-clean.
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err),
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

  task automatic do_write(input logic [31:0] a, input logic [31:0] d, input bit smm);
    int guard;
    begin
      @(negedge clk);
      smm_active = smm;
      c_addr = a; c_wdata = d; c_wstrb = 4'b1111; c_we = 1'b1; c_req = 1'b1;
      guard = 0;
      while (guard < 300 && !c_ack) begin @(posedge clk); guard++; end
      if (guard >= 300) begin
        $display("  FAIL write %08h (smm=%0b) NEVER ACKED -- a denied access must", a, smm);
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

    if (fails == 0) $display("L1AXISMRAM-GATE-OK (SMRAM isolated; SMM and normal memory unaffected)");
    else            $display("L1AXISMRAM-GATE-FAIL (%0d)", fails);
    $finish;
  end
endmodule
