// core/exec_int.sv — Integer execution units: 2x ALU, shifter, mul, div, flags
//                    (M0 stub).
//
// PLAN.md §6.3 (Integer execution): the EX/WB datapath — two integer ALUs, the
// barrel shifter, multiplier, radix-? divider, flags-logic, and the full
// bypass/interlock network feeding U and V pipes.
// Key reference: Pentium Dev. Manual Vol.1 (241428) ch.2 (EX/WB stages);
// Alpert & Avnon IEEE Micro 1993 p.2; Agner Fog P5 latency/throughput tables
// (03-optimization-timing/) for per-op latencies.
//
// M0 status: STUB. No execution. Integer ALU subset is the M1 gate (PLAN §7).

module exec_int (
    input  logic        clk,
    input  logic        rst_n
    // M1+ skeleton (not yet wired):
    //   input  logic         issue_u, issue_v,
    //   input  logic [31:0]  op_a_u, op_b_u, op_a_v, op_b_v,
    //   input  logic [3:0]   alu_op_u, alu_op_v,
    //   output logic [31:0]  res_u, res_v,
    //   output logic [31:0]  eflags_next,
    //   output logic         wb_valid_u, wb_valid_v
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : exec_int
