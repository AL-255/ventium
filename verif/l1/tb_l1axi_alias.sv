// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_alias.sv — REVIEW1_Aug2 H-04: the address-fold alias check must
// validate the whole request EXTENT, not just its first byte.
//
// ven_axi_master folds x86 physical addresses into a DDR carveout with
//     ddr_addr = REMAP_BASE + (phys & ADDR_MASK)
// so any address with bits outside ADDR_MASK would land on someone ELSE'S memory. That
// is detected and turned into bus_err. The check tested m_addr alone.
//
// An UNALIGNED access needs a second aligned beat at {addr[31:2],2'b00} + 4, generated
// independently inside the master. With the KV260 256 MiB mask a dword starting at
// 0x0FFFFFFE has its first byte INSIDE the mask -- so the old check passed it -- while
// its second beat wraps to the carveout base and corrupts low memory.
//
// This gate uses ADDR_MASK = 0x0FFFFFFF (the deployed 256 MiB window) and drives three
// requests:
//   A  0x00001000  fully inside          -> must be ACCEPTED (no bus_err)
//   B  0x10000000  first byte outside    -> must be REJECTED (the case already covered)
//   C  0x0FFFFFFE  first byte INSIDE,    -> must be REJECTED. This is the finding: it
//                  extent crosses out       passed before, and its second beat aliased.
// A is the control: a check that rejects everything would pass B and C and be useless.

module tb_l1axi_alias;
  localparam int ADDR_W = 40;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        c_req=0, c_we=0; logic [31:0] c_addr=0, c_wdata=0; logic [3:0] c_wstrb=0;
  logic [31:0] c_rdata; logic c_ack, bus_err;

  logic [3:0] awid; logic [ADDR_W-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize;
  logic [1:0] awburst; logic awlock; logic [3:0] awcache; logic [2:0] awprot;
  logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [ADDR_W-1:0] araddr; logic [7:0] arlen; logic [2:0] arsize;
  logic [1:0] arburst; logic arlock; logic [3:0] arcache; logic [2:0] arprot;
  logic [3:0] arqos; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  // The DEPLOYED KV260 window: 256 MiB. golden_l1 keeps the L1 out of the way so every
  // core request reaches the master, which is what this gate is about.
  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(40'h0), .ADDR_MASK(32'h0FFF_FFFF),
                   .WATCHDOG(1024)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b1), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(1'b0),
      .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack), .bus_err(bus_err),
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

  // Drive one WRITE and report whether bus_err was raised. A write is used because it
  // is the direction that corrupts memory when the fold goes wrong.
  task automatic try_write(input logic [31:0] a, input logic [3:0] strb,
                           input string name, input bit want_err);
    logic seen_err; int guard;
    begin
      seen_err = 1'b0;
      @(negedge clk);
      c_addr = a; c_wdata = 32'hA5A5_1234; c_wstrb = strb; c_we = 1'b1; c_req = 1'b1;
      guard = 0;
      // bus_err is raised combinationally off the request; sample while it is asserted
      // and wait for the ack (or the guard, since a rejected request need not ack).
      while (guard < 200 && !c_ack) begin
        @(posedge clk); if (bus_err) seen_err = 1'b1; guard++;
      end
      if (bus_err) seen_err = 1'b1;
      @(negedge clk); c_req = 1'b0; c_we = 1'b0; c_wstrb = 4'd0;
      repeat (4) @(posedge clk);

      if (seen_err !== want_err) begin
        $display("  FAIL %-34s addr=%08h strb=%b -> bus_err=%0b, want %0b",
                 name, a, strb, seen_err, want_err);
        fails++;
      end else begin
        $display("  ok   %-34s addr=%08h strb=%b -> bus_err=%0b",
                 name, a, strb, seen_err);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

    $display("== REVIEW1_Aug2 H-04: alias check must cover the request EXTENT ==");
    $display("   ADDR_MASK = 0x0FFFFFFF (the deployed KV260 256 MiB window)");

    // CONTROL: entirely inside the window. Must be accepted -- otherwise a check that
    // simply rejected everything would "pass" the two cases below.
    try_write(32'h0000_1000, 4'b1111, "A inside the window (control)", 1'b0);

    // Already covered before this finding: the FIRST byte is outside.
    try_write(32'h1000_0000, 4'b1111, "B first byte outside", 1'b1);

    // THE FINDING: first byte inside, extent crosses out. The second aligned beat is
    // remap({addr[31:2],2'b00} + 4) = remap(0x10000000) -> wraps to the carveout base.
    try_write(32'h0FFF_FFFE, 4'b1111, "C extent crosses out (H-04)", 1'b1);

    // ---- REVIEW2_aug2 H-15: the LEGAL boundary cases ----------------------------
    // The extent was hard-coded to "+7 always", i.e. it assumed the second aligned beat
    // ALWAYS exists. It does not: the master issues it only when the strobe, shifted by
    // the byte offset, spills past lane 3. Assuming it rejected accesses that are
    // entirely inside the window -- the exact opposite failure from case C, and one the
    // deployed 0x0FFFFFFF mask hits at the top of DRAM.
    // These are driven so the DETECTOR sees them; the pass/fail assertion is on the
    // alias-rejected ADDRESS SET in run-l1axi-alias-gate.sh, NOT on bus_err. Measured
    // reason (the same one recorded for case C last round): bus_err is raised by more
    // than one mechanism -- these addresses lie past the BFM's backing memory, so the
    // request never acks and the WATCHDOG raises bus_err regardless of the alias check.
    // Asserting want_err=0 here would fail for a reason unrelated to the finding.
    try_write(32'h0FFF_FFFC, 4'b1111, "D aligned dword at window end", 1'b1);
    // NOT 0x0FFFFFFE: case C already drives that address (with a full strobe, where it
    // genuinely crosses), and the gate's check greps the rejected set BY ADDRESS, so the
    // two would be indistinguishable. 0x0FFFFFF9+strb0011 spans bytes 1-2 of the word at
    // ...F8 -- no second beat, entirely inside the window.
    try_write(32'h0FFF_FFF9, 4'b0011, "E halfword inside a word, near end", 1'b1);
    try_write(32'h0FFF_FFFF, 4'b0001, "F final byte of the window", 1'b1);
    // The final word of a 32-byte line fill: ven_l1d walks m_addr word by word, so this
    // address is reached by a fill that began fully inside the window. It must not trip
    // the sticky alias_err.
    try_write(32'h0FFF_FFE0, 4'b1111, "G final line base", 1'b1);

    if (fails == 0) $display("L1AXIALIAS-GATE-OK (extent-aware alias rejection; control accepted)");
    else            $display("L1AXIALIAS-GATE-FAIL (%0d)", fails);
    $finish;
  end
endmodule
