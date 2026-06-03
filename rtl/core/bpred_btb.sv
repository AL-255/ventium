// core/bpred_btb.sv — Branch prediction: 256-entry 4-way BTB + 2-bit predictor
//                     (M0 stub).
//
// PLAN.md §6.1 (Front end) / PLAN §2 "Branch prediction": a 256-entry, 4-way
// set-associative BTB (64 sets) with 2-bit/4-state saturating counters,
// accessed in D1. Policy: BTB-miss => predict not-taken; first-taken allocates
// and mispredicts; mispredict resolved at WB. Penalty 3 (U) / 4 (V) cycles.
// Key reference: Alpert & Avnon IEEE Micro 1993 p.3 Fig.6 (the BTB structure);
// Intel AP-500 (241799) + Agner Fog (penalties). (M4 gate, PLAN §7.)
//
// M0 status: STUB. No prediction (no fetch yet). Lands at M4 (PLAN §7).
// Geometry constants kept here as the single source of truth for later blocks.

module bpred_btb #(
    parameter int BTB_SETS = 64,   // 256 entries / 4 ways
    parameter int BTB_WAYS = 4
) (
    input  logic        clk,
    input  logic        rst_n
    // M4+ skeleton (not yet wired):
    //   input  logic [31:0]  query_pc,      // D1 lookup
    //   output logic         predict_taken,
    //   output logic [31:0]  predict_target,
    //   input  logic         resolve_valid, // WB update
    //   input  logic [31:0]  resolve_pc, resolve_target,
    //   input  logic         resolve_taken
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : bpred_btb
