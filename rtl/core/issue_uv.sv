// core/issue_uv.sv — Integer execution: U/V dual-issue control + pairing
//                    (M0 stub).
//
// PLAN.md §6.3 (Integer execution): U-pipe (full-feature) and V-pipe
// (restricted) issue/control, the pairing checker, and the bypass/interlock +
// AGI logic that govern dual issue. One or two instructions per clock.
// Key reference: Pentium Dev. Manual Vol.1 (241428) ch.2 (pairing rules);
// Alpert & Avnon IEEE Micro 1993 p.3 Fig.5; Intel AP-500 (241799) + Agner Fog
// P5 pairing classes. (M4 gate, PLAN §7.)
//
// M0 status: STUB. Single-issue NOP stub only; the V pipe + pairing turn on at
// M4 (PLAN §7).

module issue_uv (
    input  logic        clk,
    input  logic        rst_n
    // M4+ skeleton (not yet wired):
    //   input  logic         d_pairable_u, d_pairable_v, d_microcoded,
    //   input  logic         agi_hazard, raw_hazard,
    //   output logic         issue_u,        // dispatch to U pipe
    //   output logic         issue_v,        // dispatch to V pipe (paired)
    //   output logic         paired
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : issue_uv
