// mem/tlb.sv — Address generation: separate I/D TLBs + paging walk (M0 stub).
//
// PLAN.md §6.4 (Address generation): the AGUs, segmentation + paging address
// generation, and the separate instruction / data TLBs. (Segment-descriptor
// state and CRx live in sys_state, PLAN §6.9.)
// Key reference: IA-32 SDM Vol.3 (243192) ch.3 (protected-mode address
// translation) + paging; Pentium Dev. Manual Vol.3 (241430). Alpert & Avnon
// p.5 (dual-ported D-TLB shared with the banked D-cache).
//
// M0 status: STUB. Paging/segmentation + TLBs are the M2 gate (PLAN §7).

module tlb (
    input  logic        clk,
    input  logic        rst_n
    // M2+ skeleton (not yet wired):
    //   input  logic [31:0]  lin_addr,      // linear (post-segmentation) addr
    //   input  logic         req, is_write,
    //   input  logic         paging_en,     // CR0.PG
    //   output logic [31:0]  phys_addr,
    //   output logic         hit,
    //   output logic         page_fault,    // -> exception pipeline (PLAN §6.8)
    //   output logic [3:0]   pf_errcode
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : tlb
