// core/regfile.sv — Architectural integer register file (M0 stub).
//
// PLAN.md §6.3 (Integer execution): the IA-32 GPR file (8x 32-bit:
// eax ecx edx ebx esp ebp esi edi) plus EFLAGS, with the write ports the U/V
// pipes need and the read ports decode/AGU consume. Segment selectors live in
// sys_state (PLAN §6.9). Index/order matches ventium_pkg::gpr_e and the trace
// field order in verif/diff/tracefmt.py (GPR_KEYS).
// Key reference: IA-32 SDM Vol.1 (243190) ch.3 (basic execution environment);
// Pentium Dev. Manual Vol.3 (241430).
//
// M0 status: STUB. The M0 retire point synthesises stub register state directly
// in ventium_top; a real register file lands at M1 (PLAN §7).

module regfile (
    input  logic        clk,
    input  logic        rst_n
    // M1+ skeleton (not yet wired):
    //   input  logic [2:0]   rd_sel_a, rd_sel_b,    // ventium_pkg::gpr_e
    //   output logic [31:0]  rd_data_a, rd_data_b,
    //   input  logic         wr_en_u, wr_en_v,
    //   input  logic [2:0]   wr_sel_u, wr_sel_v,
    //   input  logic [31:0]  wr_data_u, wr_data_v,
    //   output logic [31:0]  eax, ecx, edx, ebx, esp, ebp, esi, edi
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : regfile
