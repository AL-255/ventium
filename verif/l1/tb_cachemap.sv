// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_cachemap.sv — standalone unit gate for ven_cachemap (the 430FX TSC
// cacheability decoder).  Drives a golden address→attribute table derived from the
// 82437FX TSC datasheet §3.2.14/15 (PAM / DRB / DRAMC.HEN / CC.FLCE-SCFMI-SCS /
// SMRAM) and asserts the decoded {to_dram, l1_cacheable, l2_cacheable}.  Prints
// CACHEMAP-GATE-OK iff every case matches.  Run via verif/l1/run-cachemap-gate.sh.

`timescale 1ns/1ps
module tb_cachemap;

  logic [31:0] addr;
  logic        is_write, is_code, smm_active;
  logic [55:0] pam;
  logic [7:0]  dramc, cc, tom_mb4, smram;
  logic        to_dram, l1_cacheable, l2_cacheable;
  logic [3:0]  region;

  ven_cachemap dut (
      .addr(addr), .is_write(is_write), .is_code(is_code), .smm_active(smm_active),
      .pam(pam), .dramc(dramc), .cc(cc), .tom_mb4(tom_mb4), .smram(smram),
      .to_dram(to_dram), .l1_cacheable(l1_cacheable), .l2_cacheable(l2_cacheable),
      .region(region));

  int errors = 0;
  int checks = 0;

  // one expectation check (combinational DUT → settle with #1)
  task automatic chk(input string name,
                     input logic [31:0] a, input logic wr, input logic code,
                     input logic e_dram, input logic e_l1, input logic e_l2);
    addr = a; is_write = wr; is_code = code;
    #1;
    checks++;
    if (to_dram !== e_dram || l1_cacheable !== e_l1 || l2_cacheable !== e_l2) begin
      errors++;
      $display("  FAIL %-28s addr=%08h wr=%0d code=%0d : got {dram=%0d l1=%0d l2=%0d} exp {%0d %0d %0d} region=%0d",
               name, a, wr, code, to_dram, l1_cacheable, l2_cacheable, e_dram, e_l1, e_l2, region);
    end else begin
      $display("  ok   %-28s addr=%08h wr=%0d code=%0d -> {dram=%0d l1=%0d l2=%0d} region=%0d",
               name, a, wr, code, to_dram, l1_cacheable, l2_cacheable, region);
    end
  endtask

  // build a PAM nibble {Rsvd,CE,WE,RE}
  function automatic [3:0] nib(input logic ce, input logic we, input logic re);
    nib = {1'b0, ce, we, re};
  endfunction

  initial begin
    // ---- recommended integration defaults: L1 on, L2 256K-present, no force-miss,
    //      no holes, TOM = 128 MiB (tom_mb4=32), SMRAM disabled. -----------------
    cc      = 8'h41;            // SCS=01 (l2 present), SCFMI=0, FLCE=1
    dramc   = 8'h01;            // HEN=00 (no hole)
    tom_mb4 = 8'd32;            // 32 * 4 MiB = 128 MiB  (TOM = 0x0800_0000)
    smram   = 8'h00;            // SMRAM disabled
    smm_active = 1'b0;
    is_write = 1'b0; is_code = 1'b0;
    // PAM default: everything disabled (BIOS not yet shadowed) → C0000-FFFFF to PCI.
    pam = 56'h0;

    $display("[group 1] fixed DRAM + PCI windows (FLCE=1, SCS=01, no hole)");
    chk("dos_read",        32'h0000_1000, 0, 0, 1, 1, 1);   // 0-640K cacheable DRAM
    chk("dos_write",       32'h0000_1000, 1, 0, 1, 1, 1);
    chk("video_a0000",     32'h000A_0000, 0, 0, 0, 0, 0);   // video aperture → PCI, uncacheable
    chk("vga_text_b8000",  32'h000B_8000, 1, 0, 0, 0, 0);
    chk("ext_16m",         32'h0100_0000, 0, 0, 1, 1, 1);   // extended main memory, cacheable
    chk("tom_boundary",    32'h0800_0000, 0, 0, 0, 0, 0);   // exactly TOM → PCI space
    chk("pci_256m",        32'h1000_0000, 0, 0, 0, 0, 0);   // above TOM → PCI, uncacheable
    chk("apic_fec00000",   32'hFEC0_0000, 0, 0, 0, 0, 0);   // local APIC → uncacheable

    $display("[group 2] PAM-controlled ROM windows (0xC0000-0xFFFFF)");
    // System BIOS F0000-FFFFF (PAM0[7:4]) = R/W/CE → cacheable DRAM (shadowed).
    pam[7:4] = nib(1,1,1);
    chk("bios_rw_read",    32'h000F_0000, 0, 0, 1, 1, 1);
    chk("bios_rw_write",   32'h000F_8000, 1, 0, 1, 1, 1);
    // System BIOS read-only (CE=1,WE=0,RE=1): data read NOT L1-cacheable, code read
    // IS L1-cacheable, never L2; a write is forwarded to PCI (WE=0 → to_dram=0).
    pam[7:4] = nib(1,0,1);
    chk("bios_ro_dataread",32'h000F_0000, 0, 0, 1, 0, 0);
    chk("bios_ro_coderead",32'h000F_0000, 0, 1, 1, 1, 0);
    chk("bios_ro_write",   32'h000F_0000, 1, 0, 0, 0, 0);
    // Expansion ROM C8000-CBFFF (PAM2[3:0]) disabled → all cycles to PCI.
    pam[7:4]   = nib(1,1,1);          // keep BIOS shadowed
    pam[19:16] = nib(0,0,0);          // PAM2 low = disabled
    chk("pam2_disabled",   32'h000C_8000, 0, 0, 0, 0, 0);
    // Video-BIOS C0000-C3FFF (PAM1[3:0] = pam[11:8]) = R/W/CE → cacheable DRAM.
    pam[11:8] = nib(1,1,1);           // PAM1 low nibble (0xC0000-0xC3FFF)
    chk("vbios_shadow",    32'h000C_0000, 0, 1, 1, 1, 1);

    $display("[group 3] global cache gates (CC.FLCE / SCFMI / SCS)");
    cc = 8'h40;   // FLCE=0 → KEN# negated everywhere; routing still works
    chk("flce0_dos_read",  32'h0000_1000, 0, 0, 1, 0, 0);
    cc = 8'h43;   // FLCE=1, SCFMI=1 → L1 cacheable but L2 force-miss
    chk("scfmi_dos_read",  32'h0000_1000, 0, 0, 1, 1, 0);
    cc = 8'h01;   // FLCE=1, SCS=00 → L2 not populated; L1 still caches
    chk("scs00_dos_read",  32'h0000_1000, 0, 0, 1, 1, 0);
    cc = 8'h41;   // restore

    $display("[group 4] memory holes (DRAMC.HEN)");
    dramc = 8'h81;   // HEN=10 → 15M-16M hole
    chk("hole_15_16m",     32'h00F8_0000, 0, 0, 0, 0, 0);   // 15.5M → PCI, uncacheable
    chk("below_15m_ok",    32'h00E0_0000, 0, 0, 1, 1, 1);   // 14M still cacheable DRAM
    dramc = 8'h41;   // HEN=01 → 512K-640K hole
    chk("hole_512_640k",   32'h0009_0000, 0, 0, 0, 0, 0);   // 576K → PCI, uncacheable
    chk("below_512k_ok",   32'h0007_0000, 0, 0, 1, 1, 1);   // 448K still cacheable DRAM
    dramc = 8'h01;   // restore

    $display("[group 5] SMRAM aperture (A0000-BFFFF)");
    smram = 8'h48;   // DEN=1 (bit3), DOPEN=1 (bit6) → SMM space open → DRAM, cacheable
    chk("smram_open",      32'h000A_8000, 0, 0, 1, 1, 1);
    smram = 8'h08;   // DEN=1, DOPEN=0, not in SMM → still video aperture → PCI
    chk("smram_closed",    32'h000A_8000, 0, 0, 0, 0, 0);
    smm_active = 1'b1;   // DEN=1, in SMM → SMM space visible → DRAM, cacheable
    chk("smram_smm",       32'h000A_8000, 0, 0, 1, 1, 1);
    smm_active = 1'b0; smram = 8'h00;

    $display("== %0d checks, %0d errors ==", checks, errors);
    if (errors == 0) $display("CACHEMAP-GATE-OK");
    else             $display("CACHEMAP-GATE-FAIL");
    $finish;
  end

endmodule
