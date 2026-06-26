// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// northbridge/ven_hostbridge_cfg.sv — the 430FX TSC host-bridge PCI configuration
// register file (Phase D.4). PCI config space bus0:dev0:func0. BIOS programs these at
// POST; they drive ven_cachemap's cfg_* inputs, so cacheability/shadowing is real (not
// the hardwired NB_* constants of Phases B/C). The PCI-config shim (port 0xCF8/0xCFC)
// decodes a bus0:dev0 cycle and presents the dword offset + byte enables + data here.
//
// Registers modeled (82437FX TSC datasheet §3.2; offsets are byte offsets in cfg space):
//   0x00 VID=8086  0x02 DID=04A3 (82437FX)        [read-only]
//   0x52 CC     Cache Control   (FLCE/SCFMI/SCS)
//   0x57 DRAMC  DRAM Control    (HEN memory hole)
//   0x59-0x5F PAM0-6  Programmable Attribute Map ({Rsvd,CE,WE,RE} per 16K segment)
//   0x64 DRB4   DRAM Row Boundary #4 = top of memory (4-MiB units)  → cfg_tom_mb4
//   0x72 SMRAM  System Management RAM Control
//
// RESET defaults are the datasheet power-up values (CC: FLCE=0/SCFMI=1 → caches OFF
// until BIOS enables them; PAM=0 → ROM windows to PCI; DRAMC=01; DRB4=02). A system
// that does not run a real BIOS can preload bootable values via the parameters.

`default_nettype none

module ven_hostbridge_cfg #(
    parameter logic [7:0]  RST_CC      = 8'h02,   // FLCE=0, SCFMI=1, SCS=00 (datasheet)
    parameter logic [7:0]  RST_DRAMC   = 8'h01,
    parameter logic [7:0]  RST_DRB4    = 8'h02,
    parameter logic [7:0]  RST_SMRAM   = 8'h00,
    parameter logic [55:0] RST_PAM     = 56'h0
) (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // ---- PCI config access (already decoded to bus0:dev0:func0 by the shim) -----
    input  wire logic        cfg_sel,       // a bus0:dev0:func0 config cycle
    input  wire logic        cfg_we,        // 1 = config write
    input  wire logic [7:0]  cfg_off,       // byte offset (dword-aligned: [1:0]=0)
    input  wire logic [3:0]  cfg_be,        // byte enables within the dword
    input  wire logic [31:0] cfg_wdata,
    output logic [31:0]      cfg_rdata,

    // ---- decoded TSC registers → ven_cachemap ----------------------------------
    output logic [55:0]      pam,           // {PAM6..PAM0}
    output logic [7:0]       dramc,
    output logic [7:0]       cc,
    output logic [7:0]       tom_mb4,       // = DRB4
    output logic [7:0]       smram
);

  logic [7:0] cc_r, dramc_r, drb4_r, smram_r;
  logic [7:0] pam_b [0:6];                  // PAM0..PAM6 at 0x59..0x5F

  // a given byte offset is being written this cycle iff its dword matches and its lane BE.
  function automatic logic bwen(input logic [7:0] off);
    bwen = cfg_sel & cfg_we & (off[7:2]==cfg_off[7:2]) & cfg_be[off[1:0]];
  endfunction
  function automatic logic [7:0] bwdat(input logic [7:0] off);
    bwdat = cfg_wdata[{off[1:0],3'b000} +: 8];
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cc_r<=RST_CC; dramc_r<=RST_DRAMC; drb4_r<=RST_DRB4; smram_r<=RST_SMRAM;
      for (int i=0;i<7;i++) pam_b[i] <= RST_PAM[i*8 +: 8];
    end else begin
      if (bwen(8'h52)) cc_r    <= bwdat(8'h52);
      if (bwen(8'h57)) dramc_r <= bwdat(8'h57);
      if (bwen(8'h64)) drb4_r  <= bwdat(8'h64);
      if (bwen(8'h72)) smram_r <= bwdat(8'h72);
      for (int i=0;i<7;i++)
        if (bwen(8'(8'h59+i))) pam_b[i] <= bwdat(8'(8'h59+i));
    end
  end

  // ---- config read: assemble the addressed dword from the byte registers -------
  function automatic logic [7:0] regval(input logic [7:0] off);
    unique case (off)
      8'h00:   regval = 8'h86;          // VID lo
      8'h01:   regval = 8'h80;          // VID hi
      8'h02:   regval = 8'hA3;          // DID lo (82437FX)
      8'h03:   regval = 8'h04;          // DID hi
      8'h52:   regval = cc_r;
      8'h57:   regval = dramc_r;
      8'h59,8'h5A,8'h5B,8'h5C,8'h5D,8'h5E,8'h5F: regval = pam_b[off - 8'h59];
      8'h64:   regval = drb4_r;
      8'h72:   regval = smram_r;
      default: regval = 8'h00;
    endcase
  endfunction
  assign cfg_rdata = cfg_sel ? {regval(8'(cfg_off+8'd3)), regval(8'(cfg_off+8'd2)),
                                regval(8'(cfg_off+8'd1)), regval(cfg_off)} : 32'd0;

  assign pam     = {pam_b[6],pam_b[5],pam_b[4],pam_b[3],pam_b[2],pam_b[1],pam_b[0]};
  assign cc      = cc_r;
  assign dramc   = dramc_r;
  assign tom_mb4 = drb4_r;
  assign smram   = smram_r;

endmodule : ven_hostbridge_cfg

`default_nettype wire
