// mem/dcache.sv — L1 data cache: banked, MESI, dual-ported (M0 stub).
//
// PLAN.md §6.5 (Data memory): 8 KB, 2-way, 32-byte line, 8-way interleaved
// banks, write-back MESI, LRU, dual-ported TLB/tags. U-pipe wins bank
// conflicts. Plus write buffers, store/load ordering, and misalignment/
// page-split handling (+3 cycles misaligned).
// Key reference: Alpert & Avnon IEEE Micro 1993 p.5 Fig.7 (the banked D-cache);
// Intel AP-500 (241799) (misalign penalty); Pentium Dev. Manual Vol.1 (241428)
// ch.3 (MESI). Geometry matches p5model.c.
//
// M0 status: STUB. Functional D-cache at M2, banked-timing/MESI at M5 (PLAN §7).

module dcache #(
    parameter int SIZE_B = 8192,   // 8 KB
    parameter int WAYS   = 2,
    parameter int LINE_B = 32,     // => 128 sets
    parameter int BANKS  = 8       // 8-way interleaved
) (
    input  logic        clk,
    input  logic        rst_n
    // M2+ skeleton (not yet wired):
    //   // dual port: U pipe + V pipe loads/stores
    //   input  logic [31:0]  u_paddr, v_paddr,
    //   input  logic         u_req,   v_req,
    //   input  logic         u_we,    v_we,
    //   input  logic [31:0]  u_wdata, v_wdata,
    //   output logic [31:0]  u_rdata, v_rdata,
    //   output logic         u_hit,   v_hit,
    //   // MESI snoop + writeback to BIU:
    //   input  logic         snoop_req,
    //   output logic         hitm
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : dcache
