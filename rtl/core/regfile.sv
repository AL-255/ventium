`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/regfile.sv — architectural General-Purpose Register file
//                   (extracted from core.sv, R3; behaviour-preserving).
//
// A plain REGISTERED register file: storage + a synchronous reset + one
// write-enable/write-data line PER register, plus combinational read-out. It
// holds NO instruction logic — the write enables/data are driven from the
// spine's various commit sites (the writeback driver), so each register is
// written from one place and the file itself stays trivially readable.
//
// Per-register write ports (gpr_we[i] / gpr_wd[i]) rather than a muxed
// addr/data port: several P5 arms commit two registers in the same clock
// (e.g. a stack op writes the destination AND ESP; MUL/DIV writes EAX AND EDX),
// so a per-register enable needs no priority mux and the spine simply asserts
// the lines it needs.
//
// RESET is SYNCHRONOUS (posedge-clk, gated by rst_n) to match the original
// core.sv FSM reset arm VERBATIM — the two boot modes seed different values:
//   system (boot_mode=1): EDX = P5/P54C CPUID signature (cosim_en ? 0x543 :
//                         0x663), all other GPRs 0.
//   user   (boot_mode=0): ESP = init_esp, all other GPRs 0.
// gpr_o exposes the registered array (PRE-edge state) so the spine's
// combinational reads (reg_read / decode EA / retire snapshot) are unchanged.

module regfile
  import ventium_pkg::*;
(
    input  logic                clk,
    input  logic                rst_n,
    // reset seed
    input  logic                boot_mode,   // 1 = system cold reset, 0 = user
    input  logic                cosim_en,    // selects EDX 0x543 vs 0x663 (sys)
    input  logic [31:0]         init_esp,    // user-mode ESP seed
`ifdef VEN_SNAPSHOT_RESTORE
    // Reset-only user-mode checkpoint seed. System resets retain their
    // architecturally specified CPUID-signature state.
    input  logic                init_restore,
    input  logic [31:0]         init_eax,
    input  logic [31:0]         init_ecx,
    input  logic [31:0]         init_edx,
    input  logic [31:0]         init_ebx,
    input  logic [31:0]         init_ebp,
    input  logic [31:0]         init_esi,
    input  logic [31:0]         init_edi,
`endif
    // per-register write bus (driven by the spine writeback driver)
    input  logic [NUM_GPR-1:0]  gpr_we,
    input  logic [31:0]         gpr_wd [NUM_GPR],
    // read-out (registered state, combinationally visible)
    output logic [31:0]         gpr_o [NUM_GPR]
);

  logic [31:0] gpr [NUM_GPR];   // eax ecx edx ebx esp ebp esi edi

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // dual boot-mode reset — VERBATIM from the original core.sv FSM arm.
`ifdef VEN_SNAPSHOT_RESTORE
      if (!boot_mode && init_restore) begin
        gpr[0] <= init_eax;
        gpr[1] <= init_ecx;
        gpr[2] <= init_edx;
        gpr[3] <= init_ebx;
        gpr[4] <= init_esp;
        gpr[5] <= init_ebp;
        gpr[6] <= init_esi;
        gpr[7] <= init_edi;
      end else begin
`endif
      gpr[0] <= 32'd0;
      gpr[1] <= 32'd0;
      // task #102: reset EDX = P5/P54C CPUID signature 0x543 for BOTH the Win95
      // co-sim AND the SoC. The SoC previously seeded 0x663 (qemu's DEFAULT cpu,
      // family-6), but the boot oracle is qemu-system-i386 `-cpu pentium` whose
      // reset EDX is 0x543 — matching the corrected SoC CPUID(1) table (a P6
      // signature made go32/CWSDPMI derail; see core_gpr_wb.svh K_CPUID).
      gpr[2] <= boot_mode ? 32'h0000_0543 : 32'd0;
      gpr[3] <= 32'd0;
      gpr[4] <= boot_mode ? 32'd0 : init_esp;
      gpr[5] <= 32'd0;
      gpr[6] <= 32'd0;
      gpr[7] <= 32'd0;
`ifdef VEN_SNAPSHOT_RESTORE
      end
`endif
    end else begin
      for (int i = 0; i < NUM_GPR; i++)
        if (gpr_we[i]) gpr[i] <= gpr_wd[i];
    end
  end

  assign gpr_o = gpr;

endmodule : regfile
