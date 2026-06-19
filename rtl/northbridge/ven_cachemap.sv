// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// northbridge/ven_cachemap.sv — the 430FX "Triton" TSC cacheability decoder
// (the "KEN# generator").  Combinational: a physical address + cycle type in,
// the {route, L1-cacheable, L2-cacheable} attributes out.  This is the SINGLE
// place "what to cache and what not to" is decided; icache, ven_l1d, ven_l2, and
// the northbridge bypass router all consume the SAME decode so they can never
// disagree (the P5 KEN#/CACHE# model).  See docs/northbridge-system-spec.md §2.
//
// FAITHFUL to the 82437FX TSC register map (ventium-refs/01-intel-canonical/
// CHIPSET/29051801_...TRITON...82437FX...Dec95.pdf.pdf, §3.2):
//   CC    (0x52)  Cache Control:  FLCE[0] = first-level (KEN#) enable;
//                 SCFMI[1] = secondary-cache force-miss; SCS[7:6] = L2 size
//                 (00 = L2 not populated/disabled).  §3.2.10.
//   DRAMC (0x57)  DRAM Control:   HEN[7:6] = memory Hole ENable
//                 (01 = 512K-640K hole, 10 = 15M-16M hole → forwarded to PCI,
//                 non-cacheable).  §3.2.11.
//   PAM0-6(0x59-5F) Programmable Attribute Map: 14 segments over 0xC0000-0xFFFFF,
//                 each a 4-bit nibble {Rsvd[3], CE[2], WE[1], RE[0]}.  §3.2.14:
//                   RE=1 → CPU reads go to main memory (else to PCI)
//                   WE=1 → CPU writes go to main memory (else to PCI)
//                   CE=1 → L1 cacheable (CE must be 0 when RE=0).  CE=1 & WE=0
//                          (read-only) → L1-cacheable on CODE reads ONLY, and
//                          "These regions are NOT cached in the second level
//                          cache."  R/W (RE&WE) → cached in L1 AND L2.
//   DRB4  (0x64)  DRAM Row Boundary #4 = top of populated DRAM, in 4-MB units.
//                 "Extended memory 1M..TOM is cacheable; PCI memory space from
//                 the top of main memory to 4G is always non-cacheable."  §3.2.15.
//   SMRAM (0x72)  SMM RAM Control: the A0000-BFFFF aperture is normally forwarded
//                 to PCI and NON-cacheable; it becomes DRAM-backed SMM space when
//                 SMRAM enabled (DEN) and open (DOPEN) / SMM-active.  §3.2.17.
//
// FIXED (non-programmable) regions, per §3.2.14 "Memory Map":
//   0x00000-0x9FFFF  DOS area     — RE/WE/CE always enabled → cacheable DRAM
//                                   (except a 512K-640K hole if HEN=01).
//   0xA0000-0xBFFFF  video/SMRAM  — always forwarded to PCI, NON-cacheable
//                                   (unless SMRAM open → DRAM, cacheable).
//   0xC0000-0xFFFFF  ROM windows  — per PAM (below).
//   0x100000-(TOM-1) extended mem — cacheable DRAM (except a 15M-16M hole if HEN=10).
//   TOM-0xFFFFFFFF   PCI space    — always NON-cacheable, forwarded to PCI.
//
// NOTE on `to_dram`: this is the RE/WE routing decision (main-memory vs forward
// to PCI/MMIO), NOT the cacheability.  The northbridge router uses it to send a
// cycle down the L2/DDR path vs the bypass/southbridge path; the cache-enables
// gate allocation independently.  Port-I/O (IN/OUT, the core's io_* bus) never
// reaches here — it is a separate, inherently-uncacheable bus.
//
// PURE COMBINATIONAL + register-INPUTS: the CC/DRAMC/PAM/DRB4/SMRAM storage lives
// in PCI config space (bus0:dev0, the host bridge — Phase C/D wires the PCI-config
// shim to it); this decoder just reads the live values.  That keeps it trivially
// unit-testable (verif/l1/tb_cachemap.sv) and lets one instance feed every
// consumer.  RECOMMENDED INTEGRATION DEFAULTS (so the system boots without a real
// BIOS programming the TSC): cc={SCS=01,FLCE=1}=8'h41, dramc=8'h01 (no hole),
// pam all-R/W/CE for the regions FreeDOS shadows, tom_mb4 = DRAM_BYTES/4MiB.

module ven_cachemap (
    // ---- the cycle being classified ------------------------------------------
    input  logic [31:0] addr,          // physical address
    input  logic        is_write,      // 1 = write cycle (uses WE), 0 = read (uses RE)
    input  logic        is_code,       // 1 = instruction (code) read — read-only regions
                                       //     are L1-cacheable for code reads only
    input  logic        smm_active,    // 1 = CPU in SMM (SMIACT#) — gates SMRAM aperture

    // ---- live TSC configuration registers (PCI cfg bus0:dev0) ----------------
    input  logic [55:0] pam,           // {PAM6,PAM5,PAM4,PAM3,PAM2,PAM1,PAM0}, PAM0=pam[7:0]
    input  logic [7:0]  dramc,         // DRAM Control  (HEN = dramc[7:6])
    input  logic [7:0]  cc,            // Cache Control (FLCE=cc[0], SCFMI=cc[1], SCS=cc[7:6])
    input  logic [7:0]  tom_mb4,       // DRB4: top of DRAM, in 4-MiB units (TOM = tom_mb4<<22)
    input  logic [7:0]  smram,         // SMRAM control (DEN=smram[3], DOPEN=smram[6])

    // ---- decoded attributes ---------------------------------------------------
    output logic        to_dram,       // 1 = main memory (L2/DDR path); 0 = forward to PCI/MMIO
    output logic        l1_cacheable,  // KEN# analogue: L1 (icache/ven_l1d) may cache this line
    output logic        l2_cacheable,  // ven_l2 (write-back) may cache this line
    output logic [3:0]  region         // matched region (debug / coverage), see region_e
);

  // region codes (debug/coverage only)
  localparam logic [3:0] R_DOS   = 4'd0;   // 0-640K main memory
  localparam logic [3:0] R_HOLE  = 4'd1;   // an enabled memory hole → PCI
  localparam logic [3:0] R_VID   = 4'd2;   // A0000-BFFFF video aperture → PCI
  localparam logic [3:0] R_SMM   = 4'd3;   // A0000-BFFFF as open SMRAM → DRAM
  localparam logic [3:0] R_PAM   = 4'd4;   // C0000-FFFFF ROM window (PAM-controlled)
  localparam logic [3:0] R_EXT   = 4'd5;   // 1M-(TOM-1) extended main memory
  localparam logic [3:0] R_PCI   = 4'd6;   // TOM-4G PCI memory space

  // ---- config field extracts -------------------------------------------------
  logic       flce;                    // first-level (KEN#) enable
  logic       scfmi;                   // secondary-cache force-miss
  logic       l2_present;              // SCS != 00 (L2 populated/enabled)
  logic [1:0] hen;                     // memory-hole enable
  logic       smram_en, smram_open;    // SMRAM aperture enable / open
  assign flce       = cc[0];
  assign scfmi      = cc[1];
  assign l2_present = (cc[7:6] != 2'b00);
  assign hen        = dramc[7:6];
  assign smram_en   = smram[3];
  assign smram_open = smram[6];

  // ---- top of main memory (DRB4, 4-MiB granularity) --------------------------
  logic [31:0] tom;
  assign tom = {tom_mb4, 22'd0};       // tom_mb4 * 4 MiB

  // ---- the two memory holes (DRAMC.HEN) --------------------------------------
  // 512K-640K = 0x80000-0x9FFFF; 15M-16M = 0xF00000-0xFFFFFF.  When enabled the
  // CPU cycle is passed to PCI and is non-cacheable (the line is not in DRAM).
  logic in_hole_lo, in_hole_hi, in_hole;
  assign in_hole_lo = (hen == 2'b01) && (addr[31:17] == 15'h0004);            // 0x80000-0x9FFFF
  assign in_hole_hi = (hen == 2'b10) && (addr >= 32'h00F0_0000) && (addr <= 32'h00FF_FFFF);
  assign in_hole    = in_hole_lo || in_hole_hi;

  // ---- PAM nibble select for 0xC0000-0xFFFFF ---------------------------------
  // 0xC0000-0xEFFFF: 12 segments of 16 KiB.  seg = addr[19:14]-0x30 ∈ 0..11;
  //   PAM index = 1 + seg/2 (PAM1..PAM6), nibble = seg[0] ? [7:4] : [3:0].
  // 0xF0000-0xFFFFF: one 64 KiB segment → PAM0[7:4].
  logic [5:0]  seg;                    // 16-KiB segment number within C/D/E
  logic [2:0]  pam_idx;                // which PAM register (0..6)
  logic        pam_hi;                 // high nibble [7:4] vs low [3:0]
  logic [7:0]  pam_byte;
  logic [3:0]  pam_nib;                // {Rsvd, CE, WE, RE}
  always_comb begin
    seg = addr[19:14] - 6'h30;
    if (addr[19:16] == 4'hF) begin     // 0xF0000-0xFFFFF — system BIOS, PAM0[7:4]
      pam_idx = 3'd0; pam_hi = 1'b1;
    end else begin                     // 0xC0000-0xEFFFF — PAM1..PAM6
      pam_idx = 3'd1 + seg[3:1];        // 1 + seg/2  (seg ∈ 0..11 → PAM1..PAM6)
      pam_hi  = seg[0];
    end
    pam_byte = pam[{pam_idx, 3'b000} +: 8];
    pam_nib  = pam_hi ? pam_byte[7:4] : pam_byte[3:0];
  end
  logic pam_re, pam_we, pam_ce;
  assign pam_re = pam_nib[0];
  assign pam_we = pam_nib[1];
  assign pam_ce = pam_nib[2];

  // ---- the decode ------------------------------------------------------------
  // Per region, produce {to_dram, base L1-cacheable, base L2-cacheable}; the FLCE
  // / SCFMI / SCS global gates are applied once at the end.
  logic dram_route;                    // pre-FLCE: cycle targets DRAM
  logic l1c_raw;                       // pre-FLCE: region is L1-cacheable for this cycle
  logic l2c_raw;                       // pre-FLCE/SCFMI/SCS: region is L2 (write-back) cacheable
  always_comb begin
    region     = R_DOS;
    dram_route = 1'b0;
    l1c_raw    = 1'b0;
    l2c_raw    = 1'b0;

    if (addr < 32'h000A_0000) begin
      // 0-640K DOS area: RE=WE=CE=1, fully cacheable DRAM — unless a low hole.
      if (in_hole_lo) begin region = R_HOLE; dram_route = 1'b0; end
      else            begin region = R_DOS;  dram_route = 1'b1; l1c_raw = 1'b1; l2c_raw = 1'b1; end
    end else if (addr < 32'h000C_0000) begin
      // A0000-BFFFF video aperture: PCI + non-cacheable, OR open SMRAM → DRAM.
      if (smram_en && (smram_open || smm_active)) begin
        region = R_SMM; dram_route = 1'b1; l1c_raw = 1'b1; l2c_raw = 1'b1;   // SMM space is cacheable DRAM
      end else begin
        region = R_VID; dram_route = 1'b0;                                   // forwarded to PCI, uncacheable
      end
    end else if (addr < 32'h0010_0000) begin
      // C0000-FFFFF ROM windows — fully PAM-controlled.
      region     = R_PAM;
      dram_route = is_write ? pam_we : pam_re;
      // CE→L1 cacheable; read-only (WE=0) regions are L1-cacheable on CODE reads
      // only; R/W regions are L1-cacheable for reads and writes.
      l1c_raw    = pam_ce && pam_re && (pam_we || is_code);
      // R/W regions are L2-cacheable; read-only regions are NOT in L2 (datasheet).
      l2c_raw    = pam_ce && pam_re && pam_we;
    end else if (addr < tom) begin
      // 1M..(TOM-1) extended main memory: cacheable DRAM — unless the 15-16M hole.
      if (in_hole_hi) begin region = R_HOLE; dram_route = 1'b0; end
      else            begin region = R_EXT;  dram_route = 1'b1; l1c_raw = 1'b1; l2c_raw = 1'b1; end
    end else begin
      // TOM..4G PCI memory space: always non-cacheable, forwarded to PCI.
      region = R_PCI; dram_route = 1'b0;
    end
  end

  // ---- global gates ----------------------------------------------------------
  // KEN# (l1) requires FLCE.  L2 caching additionally requires the L2 be present
  // (SCS != 00) and force-miss off (SCFMI), and is meaningless if not L1-cacheable.
  assign to_dram      = dram_route;
  assign l1_cacheable = flce && l1c_raw && !in_hole;
  assign l2_cacheable = flce && l2_present && !scfmi && l2c_raw && !in_hole;

endmodule : ven_cachemap
