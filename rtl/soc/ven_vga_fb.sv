// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_vga_fb.sv — Ventium SoC: VGA mode-13h CHAIN-4 linear video memory (M8.6).
//
// A 64 KiB on-die VRAM aperture at 0xA0000 for DOS mode 13h (320x200x256). This is
// the ONLY CPU-visible piece missing on the path to the first Quake frame: the
// pixel memory itself (the VGA *register* set already lives in ven_vgaregs).
//
// GROUNDING (authoritative): QEMU 8.2.2 hw/display/vga.c vga_mem_readb/writeb, the
// CHAIN-4 path. In chain-4 mode (Sequencer SR4.CHN_4M=1, memory-map window covering
// 0xA0000) CPU access to 0xA0000 is a LINEAR byte map: a read of 0xA0000+N returns
// vram[N] directly (no latch/plane-select), and a write of 0xA0000+N lands in vram[N]
// iff the plane-write mask SR2 bit (N&3) is set (vga.c chain-4: plane = addr&3,
// write gated by sr[VGA_SEQ_PLANE_WRITE] & (1<<plane)). That plane gating is the
// behaviour a plain-RAM 0xA0000 gets WRONG, and the reason this dedicated module
// exists (the pvgafb differential proves it byte-identical to qemu-system).
//
// SCOPE (this slice): the chain-4 LINEAR path only. The planar/latched write-modes
// 0-3, read-mode 1, rotate/bit-mask/set-reset/odd-even/compare, the 0xB0000/0xB8000
// windows, the DAC palette expansion, and scan-out/pixel rendering are NOT here —
// scan-out is the board boundary (the PS A53 reads this VRAM + palette over AXI and
// blits to DP). The SoC asserts `sel` only when chain-4 is enabled (computed from the
// live ven_vgaregs SR4/GFX bits), so non-chain-4 accesses bypass this module to
// backing RAM exactly as before -> every existing gate is unperturbed.
//
// CPU port is COMBINATIONAL (single-beat M0 mem contract: rdata + ack same cycle).
// The byte plane of strobe-lane i is (addr+i)&3 (memmodel.cpp: lane i -> addr+i),
// which is convention-independent (byte-addressed or dword+wstrb both land plane =
// true-byte-addr & 3).

`default_nettype none

module ven_vga_fb (
    input  wire logic        clk,
    input  wire logic        rst,        // synchronous, active-high (PC RESET)

    // ---- CPU memory view (asserted by the SoC only when chain-4 is enabled) ---
    input  wire logic        sel,        // VRAM access this clock (decode & chain4_en)
    input  wire logic        we,         // 1 = write, 0 = read
    input  wire logic [15:0] addr,       // offset within the 64 KiB window (= masked_addr[15:0])
    input  wire logic [31:0] wdata,
    input  wire logic [3:0]  wstrb,       // per-byte write strobes (lane i -> addr+i)
    input  wire logic [3:0]  plane_mask,  // SR2[3:0] plane-write mask (chain-4 gate)
    output logic [31:0]      rdata,        // COMBINATIONAL: the 4 bytes at addr..addr+3

    // ---- scan-out read port (board seam; the PS/HDMI reads pixels here) --------
    input  wire logic [15:0] scan_addr,
    output logic [7:0]       scan_rdata
);

  // 64 KiB linear VRAM. Not reset-cleared (chain-4 reads only ever follow a write,
  // exactly like the icache data array — only the access pattern gates correctness).
  // verilator lint_off MULTIDRIVEN
  logic [7:0] vram [0:65535] /* verilator public_flat_rd */;  // F4: TB framebuffer dump
  // verilator lint_on MULTIDRIVEN

  // ---- combinational read: the 4 little-endian bytes at addr..addr+3 ----------
  // chain-4 reads are a pure identity map (no plane select), vga.c vga_mem_readb.
  always_comb begin
    rdata[7:0]   = vram[addr];
    rdata[15:8]  = vram[16'(addr + 16'd1)];
    rdata[23:16] = vram[16'(addr + 16'd2)];
    rdata[31:24] = vram[16'(addr + 16'd3)];
  end

  // ---- clocked write: per-byte chain-4 plane gating ---------------------------
  // strobe-lane i lands at offset (addr+i) iff wstrb[i] AND plane_mask[(addr+i)&3].
  always_ff @(posedge clk) begin
    if (!rst && sel && we) begin
      for (int i = 0; i < 4; i++) begin
        logic [15:0] off;
        off = 16'(addr + i[15:0]);
        if (wstrb[i] && plane_mask[off[1:0]])
          vram[off] <= wdata[i*8 +: 8];
      end
    end
  end

  // ---- scan-out (asynchronous read; board display path) -----------------------
  assign scan_rdata = vram[scan_addr];

endmodule : ven_vga_fb

`default_nettype wire
