// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/dcache_timing.sv — L1 data-cache TIMING model (extracted from core.sv, R2).
//
// PLAN.md §6.5 (Data memory): 8 KB, 2-way, 32-byte line, 128 sets, LRU. This is
// the TIMING-only model: there is NO data array — load data still comes from the
// BFM (mem_rdata in the core). This block only tracks tag/valid/LRU so the core
// can decide WHEN a load completes (read-miss adds dmiss; misaligned adds +3,
// AP-500). Mirrors p5_mem() + l1_access() in verif/qemu-plugins/p5trace.c
// (read-allocate, N-way LRU). Key reference: Alpert & Avnon IEEE Micro 1993 p.5
// Fig.7; Intel AP-500 (241799); Pentium Dev. Manual Vol.1 (241428) ch.3.
//
// PARAMETRIC GEOMETRY (DC_SETS / DC_WAYS): the default 128 sets × 2 ways is the
// silicon geometry and the one validated cycle-accurately against the oracle.
// DC_WAYS is generalised to any power of two by a per-way **age-counter true LRU**
// that reduces EXACTLY to the original 2-way behaviour at DC_WAYS==2 (same hit
// test, same victim sequence, same recency update) — so the default build stays
// bit/cycle-identical. Non-2-way geometries are functionally correct but are NOT
// matched by the fixed-2-way p5trace.so cycle oracle (they are area/perf
// experiments, not a verification config).
//
// LRU encoding: dc_age[set][way] holds the recency RANK, 0 = MRU … DC_WAYS-1 =
// LRU (the ages of a set are always a permutation of 0..DC_WAYS-1). Victim = the
// way whose age == DC_WAYS-1. On an access (hit or fill) to way k: every way
// more-recent than k (age < old age of k) ages by one, and k becomes MRU (age 0).
// At DC_WAYS==2 this is identical to the old 1-bit "dc_lru = MRU way / victim =
// ~dc_lru": reset age={0,1} → victim way 1, exactly as ~dc_lru(=0).

module dcache_timing #(
    parameter int DC_SETS = 128,
    parameter int DC_WAYS = 2,
    // Derived: idx = log2(sets), tag = 32-5-idx (32 B line => 5-bit offset);
    // way-index width = log2(ways) (>=1 so a 1-way build is legal).
    parameter int DC_IDXW = $clog2(DC_SETS),
    parameter int DC_TAGW = 32 - 5 - DC_IDXW,
    parameter int DC_WAYW = (DC_WAYS <= 1) ? 1 : $clog2(DC_WAYS)
) (
    input  logic        clk,
    input  logic        rst_n,

    // Combinational lookup (timing only): is the 32-byte line containing
    // `lu_addr` resident in any way of its set? Reads the REGISTERED arrays,
    // so it reflects the PRE-access state this clock (the allocate/LRU update is
    // applied on posedge below, a true LRU SM, not a combinational peek).
    input  logic [31:0] lu_addr,
    output logic        lu_hit,

    // Single funnelled access/allocate port: when acc_valid is high at a posedge,
    // run the N-way-LRU access on acc_addr (update LRU on a hit, else allocate the
    // LRU way). Exactly p5model l1_access().
    input  logic        acc_valid,
    input  logic [31:0] acc_addr
);

  logic [DC_TAGW-1:0] dc_tag [DC_SETS][DC_WAYS];   // addr[31:5+idx]
  logic               dc_val [DC_SETS][DC_WAYS];
  logic [DC_WAYW-1:0] dc_age [DC_SETS][DC_WAYS];   // recency rank: 0=MRU .. WAYS-1=LRU

  // D-cache hit test (timing only): is the line containing `lu_addr` resident in
  // any way of its set? Mirrors p5model l1_access() lookup. Pure-comb off the
  // registered arrays (does NOT mutate state).
  always_comb begin
    logic [DC_IDXW-1:0] set; logic [DC_TAGW-1:0] tag;
    set = lu_addr[5 +: DC_IDXW]; tag = lu_addr[5+DC_IDXW +: DC_TAGW];
    lu_hit = 1'b0;
    for (int w=0; w<DC_WAYS; w++)
      if (dc_val[set][w] && dc_tag[set][w]==tag) lu_hit = 1'b1;
  end

  // D-cache access: update LRU on a hit, else allocate the LRU way (N-way age-LRU
  // replacement, exactly p5model l1_access() at 2-way). One access per clock.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s=0;s<DC_SETS;s++)
        for (int w=0;w<DC_WAYS;w++) begin
          dc_val[s][w]<=1'b0; dc_tag[s][w]<='0;
          dc_age[s][w]<=DC_WAYW'(w);   // age = way index => victim (max age) = way WAYS-1
        end
    end else if (acc_valid) begin
      logic [DC_IDXW-1:0] set; logic [DC_TAGW-1:0] tag;
      logic hit; logic [DC_WAYW-1:0] hw, victim, k, old_a;
      set = acc_addr[5 +: DC_IDXW]; tag = acc_addr[5+DC_IDXW +: DC_TAGW];
      hit = 1'b0; hw = '0; victim = '0;
      for (int w=0; w<DC_WAYS; w++) begin
        if (dc_val[set][w] && dc_tag[set][w]==tag) begin hit=1'b1; hw=DC_WAYW'(w); end
        if (dc_age[set][w] == DC_WAYW'(DC_WAYS-1)) victim = DC_WAYW'(w);
      end
      k = hit ? hw : victim;
      if (!hit) begin dc_val[set][victim]<=1'b1; dc_tag[set][victim]<=tag; end
      // recency update: ways more-recent than k age by one; k becomes MRU.
      old_a = dc_age[set][k];
      for (int w=0; w<DC_WAYS; w++)
        if (dc_age[set][w] < old_a) dc_age[set][w] <= dc_age[set][w] + 1'b1;
      dc_age[set][k] <= '0;
    end
  end

endmodule : dcache_timing
