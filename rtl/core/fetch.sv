// core/fetch.sv — Front end: prefetch / instruction fetch (M0 stub).
//
// PLAN.md §6.1 (Front end): prefetch buffers, I-cache access, branch-address
// calc; feeds the D1/D2 decode of PLAN §6.2.
// Key reference: Alpert & Avnon, "Architecture of the Pentium Microprocessor",
// IEEE Micro 1993, p.2-3 (PF/D1/D2/EX/WB pipeline + the dual prefetch buffers);
// Pentium Dev. Manual Vol.1 (241428) ch.2.
//
// M0 status: STUB. No real fetch. Real prefetch logic lands at M1+ (PLAN §7).
// Port list below is the intended skeleton; only clk/rst_n are connected in
// ventium_top at M0.

module fetch (
    input  logic        clk,
    input  logic        rst_n
    // M1+ skeleton (not yet wired):
    //   input  logic [31:0] eip,           // architectural fetch pointer
    //   input  logic        redirect,      // branch/mispredict redirect
    //   input  logic [31:0] redirect_eip,
    //   output logic [31:0] fetch_pc,      // PC handed to decode (D1)
    //   output logic [127:0] fetch_bytes,  // raw line-aligned bytes
    //   output logic         fetch_valid
);
  // Intentionally empty at M0. clk/rst_n referenced to stay lint-clean.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : fetch
