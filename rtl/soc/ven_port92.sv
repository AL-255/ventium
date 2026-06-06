// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_port92.sv — Ventium SoC PC peripheral: System Control Port A (M8).
//
// I/O port 0x92 — the "Fast A20" / System Control Port A. 8-bit register.
// GROUNDING (authoritative): QEMU 8.2.2 hw/i386/port92.c, mirrored under
//   ventium-refs/07-p5-emulation-harness/build/qemu/hw/i386/port92.c
// This module matches the CPU-OBSERVABLE register read/write behaviour of that
// model exactly (the later differential-vs-qemu-system SoC gate checks this).
//
// QEMU semantics, register `outport` (uint8_t, init 0):
//   WRITE (port92_write):
//       oldval = outport;
//       outport = val;                       // full byte stored verbatim
//       a20_out = (val >> 1) & 1;            // bit1 -> A20 gate
//       if ((val & 1) && !(oldval & 1))      // bit0 rising edge 0->1
//           qemu_system_reset_request(GUEST_RESET);
//   READ (port92_read):
//       return outport;                      // full byte; bit1 reflects A20
//   RESET (port92_reset, PC RESET):
//       outport &= ~1;                       // clears bit0 ONLY; A20 preserved
//
// Notes on faithful mapping to the Ventium common device interface:
//  * outport is held in a register; rdata is COMBINATIONAL off it (same-cycle
//    ack contract).
//  * The reset-request "system reset" is surfaced as a 1-clock pulse on
//    reset_req on the bit0 0->1 EDGE (QEMU calls qemu_system_reset_request once
//    per edge; the SoC top turns this pulse into the actual machine reset).
//  * a20_gate is a level output continuously reflecting bit1 of outport.
//  * rst is synchronous, ACTIVE-HIGH (PC RESET). To match QEMU's port92_reset
//    (which clears ONLY bit0 and preserves the A20 bit), rst here clears bit0
//    and leaves bit1/a20 untouched. Power-on init value of outport is 0 (matches
//    QEMU port92_initfn) — modelled via the INIT value of the register, so a
//    cold machine starts with A20 masked / reset bit clear.

`default_nettype none

module ven_port92 (
    input  logic        clk,
    input  logic        rst,     // synchronous, ACTIVE-HIGH (PC RESET): clears bit0
    input  logic        cs,      // chip-select: addressed port hit (0x92)
    input  logic        we,      // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  logic [15:0] addr,    // I/O port address (unused: single-port device)
    input  logic [7:0]  wdata,   // write data (8-bit)
    output logic [7:0]  rdata,   // read data — COMBINATIONAL off outport

    // device-specific outputs
    output logic        a20_gate,   // level: bit1 of outport (A20 gate enable)
    output logic        reset_req   // 1-clk pulse on bit0 0->1 edge (CPU write)
);

  // The single CPU-visible 8-bit register. Power-on init = 0 (QEMU
  // port92_initfn sets outport=0 on a cold machine). This is an intentional
  // power-on value combined with a procedural write below; PROCASSINIT is
  // expected here and waived. (Synthesises to a register with an init/preset
  // on FPGA; on ASIC the cold value is established by the platform's first
  // PC RESET driving rst, which clears bit0, with A20 masked low externally.)
  // verilator lint_off PROCASSINIT
  logic [7:0] outport = 8'h00;
  // verilator lint_on PROCASSINIT

  // --- WRITE / RESET (clocked) ---------------------------------------------
  // reset_req is a strictly 1-clock pulse: default 0 every cycle, asserted only
  // on the cycle a qualifying write commits.
  always_ff @(posedge clk) begin
    reset_req <= 1'b0;  // default: deassert each cycle (1-clk pulse semantics)

    if (rst) begin
      // QEMU port92_reset: clear bit0 only; A20/other bits preserved.
      outport[0] <= 1'b0;
    end else if (cs && we) begin
      // CPU OUT to port 0x92.
      // Reset request edge-detect: fire iff bit0 transitions 0 -> 1.
      if (wdata[0] && !outport[0]) begin
        reset_req <= 1'b1;
      end
      outport <= wdata;  // store the full byte verbatim (matches QEMU).
    end
    // READ (cs && !we) has no side effect on this device's state.
  end

  // --- READ (combinational) ------------------------------------------------
  // QEMU port92_read returns outport unconditionally; expose it on rdata.
  assign rdata = outport;

  // --- A20 gate (level) ----------------------------------------------------
  // QEMU drives a20_out = (outport >> 1) & 1 on every write; equivalently it is
  // a continuous function of bit1 of the stored register.
  assign a20_gate = outport[1];

  // addr is part of the uniform device interface but this device decodes a
  // single port (the SoC PMIO decoder asserts cs only for 0x92).
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, addr};
  // verilator lint_on UNUSED

endmodule : ven_port92

`default_nettype wire
