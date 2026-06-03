// ucode/ucode_rom.sv — Microcode engine: control ROM + sequencer (M0 stub).
//
// PLAN.md §6.7 (Microcode engine): the control ROM + sequencer that drives
// complex / serializing / microcoded instructions (mul, div, string ops,
// far transfers, task switches, IRET, RSM, ...). Per PLAN §8 this is a
// behaviorally-equivalent engine — Intel's actual microcode ROM is unpublished,
// so cycle counts come from the timing tables, not a ROM listing.
// Key reference: Pentium Dev. Manual Vol.1 (241428) ch.2 (instruction timing /
// microcoded ops); Agner Fog P5 tables for per-op micro-op counts/latencies.
//
// M0 status: STUB. A microcode-engine stub first appears at M1, fleshed out
// across M2+ (PLAN §7).

module ucode_rom (
    input  logic        clk,
    input  logic        rst_n
    // M1+ skeleton (not yet wired):
    //   input  logic         enter,         // decode flagged a microcoded op
    //   input  logic [11:0]  entry_addr,    // ROM entry point for the opcode
    //   output logic [???]   uop,           // current micro-op (width TBD)
    //   output logic         busy,          // sequencer running (serialize)
    //   output logic         done
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : ucode_rom
