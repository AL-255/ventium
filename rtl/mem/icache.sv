// mem/icache.sv — L1 instruction cache (M0 stub).
//
// PLAN.md §6.1 (Front end) / PLAN §2 "Memory subsystem": 8 KB, 2-way
// set-associative, 32-byte line => 128 sets. Feeds the prefetch buffers.
// Key reference: Alpert & Avnon IEEE Micro 1993 p.5 (L1 organisation);
// Pentium Dev. Manual Vol.1 (241428) ch.3 (cache). Geometry matches the cycle
// oracle in ventium-refs/.../plugin/p5model.c (L1_SIZE/L1_WAYS/L1_LINE).
//
// M0 status: STUB. M0 is "no fetch"; functional I-cache lands at M2 (PLAN §7),
// timing at M5.

module icache #(
    parameter int SIZE_B = 8192,   // 8 KB
    parameter int WAYS   = 2,
    parameter int LINE_B = 32      // => 128 sets
) (
    input  logic        clk,
    input  logic        rst_n
    // M2+ skeleton (not yet wired):
    //   input  logic [31:0]  fetch_paddr,   // post-TLB physical address
    //   input  logic         fetch_req,
    //   output logic [255:0] line_data,     // 32-byte line
    //   output logic         hit,
    //   // refill path to the BIU:
    //   output logic         fill_req,
    //   input  logic         fill_ack
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : icache
