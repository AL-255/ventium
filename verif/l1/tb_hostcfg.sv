// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_hostcfg.sv — Phase D.4 gate: the TSC host-bridge PCI-config register file
// (ven_hostbridge_cfg) driving ven_cachemap. Writes the cacheability registers through the
// config port and checks the cachemap classification CHANGES accordingly — i.e. the real
// PCI-config path replaces the hardwired NB_* constants. Prints HOSTCFG-GATE-OK / -FAIL.

module tb_hostcfg;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  // config port
  logic        cfg_sel, cfg_we; logic [7:0] cfg_off; logic [3:0] cfg_be; logic [31:0] cfg_wdata, cfg_rdata;
  // decoded regs → cachemap
  logic [55:0] pam; logic [7:0] dramc, cc, tom_mb4, smram;
  ven_hostbridge_cfg u_cfg (
      .clk(clk), .rst_n(rst_n), .cfg_sel(cfg_sel), .cfg_we(cfg_we), .cfg_off(cfg_off),
      .cfg_be(cfg_be), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
      .pam(pam), .dramc(dramc), .cc(cc), .tom_mb4(tom_mb4), .smram(smram));

  // cachemap under the live config
  logic [31:0] addr; logic is_write, is_code, smm_active;
  logic to_dram, l1_cacheable, l2_cacheable; logic [3:0] region;
  ven_cachemap u_cmap (
      .addr(addr), .is_write(is_write), .is_code(is_code), .smm_active(smm_active),
      .pam(pam), .dramc(dramc), .cc(cc), .tom_mb4(tom_mb4), .smram(smram),
      .to_dram(to_dram), .l1_cacheable(l1_cacheable), .l2_cacheable(l2_cacheable), .region(region));

  int errors=0;
  task automatic chk(input string what, input logic got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask
  task automatic cfg_w(input [7:0] off, input [3:0] be, input [31:0] data);
    @(negedge clk); cfg_sel<=1; cfg_we<=1; cfg_off<=off; cfg_be<=be; cfg_wdata<=data;
    @(negedge clk); cfg_sel<=0; cfg_we<=0;
  endtask
  // classify an address: drive the cachemap and settle.
  task automatic look(input [31:0] a, input logic wr, input logic code);
    addr=a; is_write=wr; is_code=code; #1;
  endtask

  initial begin
    cfg_sel=0; cfg_we=0; cfg_off=0; cfg_be=0; cfg_wdata=0; addr=0; is_write=0; is_code=0; smm_active=0;
    repeat(3) @(posedge clk); rst_n<=1'b1; @(posedge clk); #1;

    $display("[1] RESET defaults: CC.FLCE=0 → nothing L1-cacheable (caches off until BIOS)");
    look(32'h0000_1000, 0, 0);
    chk("DOS read l1_cacheable (FLCE=0)", l1_cacheable, 1'b0);
    chk("DOS read still routes to DRAM",  to_dram,       1'b1);

    $display("[2] BIOS enables caches: write CC=0x41 (FLCE=1, SCS=01)");
    cfg_w(8'h50, 4'b0100, 32'h0041_0000);   // dword 0x50, byte 2 (0x52) = 0x41
    look(32'h0000_1000, 0, 0);
    chk("DOS read now L1 cacheable", l1_cacheable, 1'b1);
    chk("DOS read now L2 cacheable", l2_cacheable, 1'b1);

    $display("[3] shadow the system BIOS: write PAM0=0x70 (high nibble R/W/CE) → F0000 cacheable");
    cfg_w(8'h58, 4'b0010, 32'h0000_7000);   // dword 0x58, byte 1 (0x59=PAM0) = 0x70
    look(32'h000F_0000, 0, 0);
    chk("BIOS F0000 now cacheable (L1)", l1_cacheable, 1'b1);
    chk("BIOS F0000 now cacheable (L2)", l2_cacheable, 1'b1);
    chk("BIOS F0000 routes to DRAM",     to_dram,      1'b1);

    $display("[4] open a 15M-16M hole: set TOM=64M (DRB4=0x10) then DRAMC=0x81 (HEN=10)");
    cfg_w(8'h64, 4'b0001, 32'h0000_0010);   // DRB4=0x10 → TOM=64 MiB (so 14M/15.5M are in range)
    cfg_w(8'h54, 4'b1000, 32'h8100_0000);   // dword 0x54, byte 3 (0x57=DRAMC) = 0x81
    look(32'h00F8_0000, 0, 0);              // 15.5 MB
    chk("15.5M in hole → uncacheable", l1_cacheable, 1'b0);
    chk("15.5M in hole → not DRAM",    to_dram,      1'b0);
    look(32'h00E0_0000, 0, 0);              // 14 MB (below the hole)
    chk("14M below hole still cacheable", l1_cacheable, 1'b1);

    $display("[5] set top-of-memory low: write DRB4=0x04 (16 MiB) → 32M becomes PCI space");
    cfg_w(8'h64, 4'b0001, 32'h0000_0004);   // dword 0x64, byte 0 (0x64=DRB4) = 0x04
    look(32'h0200_0000, 0, 0);              // 32 MB > TOM(16M)
    chk("32M above TOM → uncacheable", l1_cacheable, 1'b0);
    chk("32M above TOM → PCI (not DRAM)", to_dram,    1'b0);
    look(32'h0080_0000, 0, 0);              // 8 MB < TOM
    chk("8M below TOM still cacheable", l1_cacheable, 1'b1);

    $display("[6] config read-back round-trips (CC, DID)");
    @(negedge clk); cfg_sel<=1; cfg_we<=0; cfg_off<=8'h50; cfg_be<=4'hF; @(posedge clk); #1;
    if (cfg_rdata[23:16] !== 8'h41) begin $display("  FAIL CC readback=%02x exp 41", cfg_rdata[23:16]); errors++; end
    else $display("  ok   CC readback = %02x", cfg_rdata[23:16]);
    @(negedge clk); cfg_off<=8'h00; @(posedge clk); #1;
    if (cfg_rdata !== 32'h04A3_8086) begin $display("  FAIL VID/DID=%08x exp 04A38086", cfg_rdata); errors++; end
    else $display("  ok   VID/DID = %08x", cfg_rdata);
    @(negedge clk); cfg_sel<=0;

    if (errors==0) $display("HOSTCFG-GATE-OK (all checks pass)");
    else           $display("HOSTCFG-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("HOSTCFG-GATE-FAIL (timeout)"); $finish; end
endmodule
