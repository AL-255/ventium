// fpu/fpu_top.sv — x87 FPU top: 8-stage pipeline + datapath (M0 stub).
//
// PLAN.md §6.6 (x87 FPU): the 8-stage FPU pipeline (PF/D1/D2/E/X1/X2/WF/ER),
// 80-bit stack file + tag word + status/control words, the FIRC/FEXP/FMUL/
// FADD/FDIV/FRND datapath blocks, the transcendental constant ROM + polynomial
// engine, Safe Instruction Recognition (SIR), and the parallel-FXCH bypass.
// Key reference: Alpert & Avnon IEEE Micro 1993 p.6-8 (Fig.8 pipeline, Fig.9
// datapath, SIR, FXCH); Agner Fog P5 FP latency table; IA-32 SDM Vol.1
// (243190) ch.7 (x87 architecture).
//
// M0 status: STUB. x87 is the M3 gate (PLAN §7). Func-mode x87 trace fields
// (trace-format.md §2.2, header x87:true) are emitted via the separate
// vtm_retire_x87 import, declared when M3 lands.

module fpu_top (
    input  logic        clk,
    input  logic        rst_n
    // M3+ skeleton (not yet wired):
    //   input  logic         fp_valid,
    //   input  logic [7:0]   fp_op,
    //   input  logic [79:0]  fp_src,
    //   output logic [79:0]  st0,           // top of x87 stack
    //   output logic [15:0]  fctrl, fstat, ftag,
    //   output logic         fp_retire
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : fpu_top
