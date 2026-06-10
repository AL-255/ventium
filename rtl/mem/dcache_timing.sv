// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/dcache_timing.sv — L1 data-cache TIMING model (extracted from core.sv, R2).
//
// PLAN.md §6.5 (Data memory): 8 KB, 2-way, 32-byte line, 128 sets, LRU. This is
// the TIMING-only model: there is NO data array — load data still comes from the
// BFM (mem_rdata in the core). This block only tracks tag/valid/LRU so the core
// can decide WHEN a load completes (read-miss adds dmiss; misaligned adds +3,
// AP-500). Mirrors p5_mem() + l1_access() in verif/qemu-plugins/p5trace.c
// (read-allocate, 2-way LRU). Key reference: Alpert & Avnon IEEE Micro 1993 p.5
// Fig.7; Intel AP-500 (241799); Pentium Dev. Manual Vol.1 (241428) ch.3.
//
// Behaviour-preserving extraction (R2): the inline dc_tag/dc_val/dc_lru arrays,
// the pure-comb dc_hit() lookup, the single dc_access() mutating task, and the
// synchronous reset loop were lifted out of core.sv verbatim. The lookup port
// (lu_addr -> lu_hit) is COMBINATIONAL off the REGISTERED arrays, so it reflects
// PRE-access state in the same clock a posedge access updates them (the
// dc_hit-then-dc_access read-before-write that func diff cannot see). All writes
// land on posedge through the single funnelled access port (acc_valid/acc_addr).
// At most ONE access/clock by construction in the core (verified mutually
// exclusive across S_PIPE U-load / S_LOAD / S_LOAD2 / S_STORE).

module dcache_timing #(
    parameter int DC_SETS = 128,
    // Derived: idx = log2(sets), tag = 32-5-idx (32 B line => 5-bit offset).
    // 128 sets => idx 7 / tag 20; the +VEN_CACHE_HALF variant passes DC_SETS=64
    // => idx 6 / tag 21. Not overridden at instantiation.
    parameter int DC_IDXW = $clog2(DC_SETS),
    parameter int DC_TAGW = 32 - 5 - DC_IDXW
) (
    input  logic        clk,
    input  logic        rst_n,

    // Combinational lookup (timing only): is the 32-byte line containing
    // `lu_addr` resident in either way of its set? Reads the REGISTERED arrays,
    // so it reflects the PRE-access state this clock (the allocate/LRU update is
    // applied on posedge below, a true LRU SM, not a combinational peek).
    input  logic [31:0] lu_addr,
    output logic        lu_hit,

    // Single funnelled access/allocate port: when acc_valid is high at a posedge,
    // run the 2-way-LRU access on acc_addr (update LRU on a hit, else allocate the
    // not-MRU way). Exactly p5model l1_access().
    input  logic        acc_valid,
    input  logic [31:0] acc_addr
);

  logic [DC_TAGW-1:0] dc_tag [DC_SETS][2];   // addr[31:5+idx]
  logic        dc_val [DC_SETS][2];
  logic        dc_lru [DC_SETS];      // 2-way LRU: way most-recently-used

  // D-cache hit test (timing only): is the line containing `lu_addr` resident in
  // either way of its set? Mirrors p5model l1_access() lookup. Pure-comb off the
  // registered arrays (does NOT mutate state).
  always_comb begin
    logic [DC_IDXW-1:0] set; logic [DC_TAGW-1:0] tag;
    set = lu_addr[5 +: DC_IDXW]; tag = lu_addr[5+DC_IDXW +: DC_TAGW];
    lu_hit = (dc_val[set][0] && dc_tag[set][0]==tag) ||
             (dc_val[set][1] && dc_tag[set][1]==tag);
  end

  // D-cache access: update LRU on a hit, else allocate the not-MRU way (2-way LRU
  // replacement, exactly p5model l1_access()). One access per clock from the core.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s=0;s<DC_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<='0; dc_tag[s][1]<='0;
      end
    end else if (acc_valid) begin
      logic [DC_IDXW-1:0] set; logic [DC_TAGW-1:0] tag; logic hit; logic victim;
      set = acc_addr[5 +: DC_IDXW]; tag = acc_addr[5+DC_IDXW +: DC_TAGW]; hit = 1'b0; victim = ~dc_lru[set];
      for (int w=0; w<2; w++)
        if (dc_val[set][w] && dc_tag[set][w]==tag) begin hit=1'b1; dc_lru[set]<=w[0]; end
      if (!hit) begin
        dc_val[set][victim]<=1'b1; dc_tag[set][victim]<=tag; dc_lru[set]<=victim;
      end
    end
  end

endmodule : dcache_timing
