// core/decode.sv — Decode: x86 length decode, prefix machine, ModR/M+SIB,
//                  D1/D2 split (M0 stub).
//
// PLAN.md §6.2 (Decode): variable-length x86 length decoder, prefix machine,
// ModR/M+SIB extraction, D1/D2 stage split, and the pairability checker (the
// U/V issue algorithm — though pairing physically lands in issue_uv at M4).
// Key reference: Pentium Dev. Manual Vol.1 (241428) ch.2; Alpert & Avnon
// IEEE Micro 1993 p.3 Fig.5 (the "simple instruction" / pairing pseudocode).
//
// M0 status: STUB. No real decode (real decode is the M1 gate, PLAN §7).

module decode (
    input  logic        clk,
    input  logic        rst_n
    // M1+ skeleton (not yet wired):
    //   input  logic [31:0]  fetch_pc,
    //   input  logic [127:0] fetch_bytes,
    //   input  logic         fetch_valid,
    //   output logic [3:0]   insn_len,      // decoded length (D1)
    //   output logic         pairable_u,    // U-pipe eligible
    //   output logic         pairable_v,    // V-pipe eligible
    //   output logic         microcoded,    // routes to ucode_rom
    //   output logic         decode_valid
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : decode
