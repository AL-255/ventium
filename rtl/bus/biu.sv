// bus/biu.sv — Bus interface unit: 64-bit P5 bus FSM (M0 stub).
//
// PLAN.md §6.10 (Bus interface unit): the 64-bit external-bus FSM — burst line
// fills, locked cycles, pipelined cycles via NA#, writebacks, snoops
// (AHOLD/EADS#, HIT#/HITM#), KEN#/CACHE#, HOLD/HLDA, BOFF#, and reset/INIT/BIST.
// Key reference: Pentium Processor Datasheet 241997-010 (01-intel-canonical/)
// — bus pin/protocol; Pentium Dev. Manual Vol.1 (241428) ch.6 (bus operation).
//
// M0 status: STUB. M0 uses the minimal bus-functional-model port group owned by
// ventium_top (docs/rtl-interface.md §3). The modeled P5 bus FSM replaces it at
// M5 (PLAN §7); these are the eventual real pins, kept here as documentation.

module biu (
    input  logic        clk,
    input  logic        rst_n
    // M5+ skeleton — real P5 bus pins (not yet wired); see datasheet 241997-010:
    //   output logic         ads_n,         // ADS#  address strobe
    //   input  logic         brdy_n,        // BRDY# burst ready
    //   input  logic         na_n,          // NA#   next address (pipelining)
    //   input  logic         ken_n,         // KEN#  cache enable
    //   output logic         cache_n,       // CACHE# cacheable cycle
    //   output logic         lock_n,        // LOCK# locked cycle
    //   input  logic         ahold, eads_n, // snoop
    //   output logic         hit_n, hitm_n,
    //   input  logic         hold,
    //   output logic         hlda,
    //   input  logic         boff_n,
    //   output logic [31:0]  bus_addr,
    //   inout  logic [63:0]  bus_data       // 64-bit data bus
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : biu
