`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/tlb_assoc.sv -- bounded associative TLB experiment.
//
// This is deliberately a SEPARATE module from tlb.sv.  The deployed/default
// core continues to instantiate the 16-entry direct-map array verbatim; the
// core selects this module only under VEN_DTLB_ASSOC_2WAY or
// VEN_DTLB_ASSOC_4WAY.  That makes a capacity/associativity experiment unable
// to perturb the established baseline through a refactor of its lookup or
// write-port semantics.
//
// Geometry for the first experiment is D-only 16 sets x {2,4} ways.  The set
// selector is therefore still lin[15:12], while the tag remains the full 4 KiB
// VPN.  In particular, fill_big intentionally preserves the legacy tlb.sv
// semantics: a PSE entry is keyed by the full 4 KiB VPN and only the physical
// offset is 4 MiB-shaped.  A faithful P54C large-page D-TLB is a distinct later
// feature; silently changing that contract here would make a performance probe
// double as an architectural paging rewrite.
//
// Replacement is invalid-way-first, then fill-only round robin.  It is NOT
// called P5 pseudo-LRU: the current core supplies an always-live lookup address
// rather than a qualified architectural touch, so mutating replacement state on
// raw hits would be wrong in idle/non-translatable states.  A later P5-fidelity
// step needs an explicit touch_en interface and its own tests.

module tlb_assoc #(
    parameter bit IS_D = 1,
    parameter int TLB_SETS = 16,
    parameter int TLB_WAYS = 2
) (
    input  logic        clk,
    input  logic        rst_n,

    // Combinational lookup.  As in tlb.sv, outputs observe pre-fill registered
    // state on a fill edge; there is no combinational fill bypass.
    input  logic [31:0] lk_lin,
    output logic        lk_hit,
    output logic [31:0] lk_phys,
    output logic [2:0]  lk_perm,
    output logic        lk_dirty,
`ifdef VEN_PIPE_MEM_CHAIN
    input  logic [31:0] next_lin,
    output logic        next_hit,
    output logic [31:0] next_phys,
    output logic [2:0]  next_perm,
    output logic        next_dirty,
`endif
`ifdef VEN_P54_DUAL_HIT
    input  logic [31:0] pair_lin,
    output logic        pair_hit,
    output logic [31:0] pair_phys,
    output logic [2:0]  pair_perm,
    output logic        pair_dirty,
`endif

    // One pulsed fill from S_WALK, followed by the same broad CR3-side flush
    // already used by tlb.sv.  The caller guarantees at most one fill/clock.
    input  logic        fill_en,
    input  logic [31:0] fill_lin,
    input  logic [19:0] fill_pfn,
    input  logic [2:0]  fill_perm,
    input  logic        fill_big,
    input  logic        fill_dirty,
    input  logic        flush_en
);

  localparam int TLB_ENTRIES = TLB_SETS * TLB_WAYS;
  localparam int SET_BITS    = $clog2(TLB_SETS);
  localparam int WAY_BITS    = $clog2(TLB_WAYS);

  // Keep these arrays flat and named like tlb.sv.  Besides making a waveform
  // comparison straightforward, this preserves the u_dtlb.tlb_* hierarchy
  // surface used by debug tools; callers must still become geometry-aware
  // before enabling an associative build.
  logic        tlb_val   [TLB_ENTRIES];
  logic [19:0] tlb_vpn   [TLB_ENTRIES];
  logic [19:0] tlb_pfn   [TLB_ENTRIES];
  logic [2:0]  tlb_perm  [TLB_ENTRIES];
  logic        tlb_big   [TLB_ENTRIES];
  logic        tlb_dirty [TLB_ENTRIES];

  // The next round-robin victim per set.  It advances only on a new allocation
  // (not an in-place same-VPN refill), and is intentionally untouched by flush.
  logic [WAY_BITS-1:0] rr_way [TLB_SETS];

  function automatic logic [SET_BITS-1:0] tlb_set(input logic [31:0] lin);
    tlb_set = lin[11 + SET_BITS:12];
  endfunction

  function automatic int slot_of(input logic [SET_BITS-1:0] set, input int way);
    slot_of = int'(set) * TLB_WAYS + way;
  endfunction

  // Lookup selects all payload fields from the SAME matching way.  In
  // particular do not derive phys from one way and permission/dirty from
  // another: that would turn an alias into silent memory corruption.
  always_comb begin : lookup_comb
    logic [SET_BITS-1:0] set;
    int ix;
    set = tlb_set(lk_lin);

    // Payloads on a miss are architecturally ignored.  Keep a deterministic
    // first-way value for simulation/debug parity with the direct-map module.
    ix       = slot_of(set, 0);
    lk_hit   = 1'b0;
    lk_phys  = tlb_big[ix] ? {tlb_pfn[ix][19:10], lk_lin[21:0]}
                           : {tlb_pfn[ix],          lk_lin[11:0]};
    lk_perm  = tlb_perm[ix];
    lk_dirty = IS_D ? tlb_dirty[ix] : 1'b0;

    for (int w = 0; w < TLB_WAYS; w++) begin
      ix = slot_of(set, w);
      // First matching way wins.  The writer below refills a matching tag in
      // place, so valid duplicate tags are prohibited rather than arbitrated.
      if (!lk_hit && tlb_val[ix] && (tlb_vpn[ix] == lk_lin[31:12])) begin
        lk_hit   = 1'b1;
        lk_phys  = tlb_big[ix] ? {tlb_pfn[ix][19:10], lk_lin[21:0]}
                               : {tlb_pfn[ix],          lk_lin[11:0]};
        lk_perm  = tlb_perm[ix];
        lk_dirty = IS_D ? tlb_dirty[ix] : 1'b0;
      end
    end
  end

`ifdef VEN_PIPE_MEM_CHAIN
  // A second combinational read of the same small array. No duplicate entries
  // or replacement state, and no speculative page-table side effects.
  always_comb begin : next_lookup_comb
    logic [SET_BITS-1:0] set;
    int ix;
    set = tlb_set(next_lin);
    next_hit = 1'b0; next_phys = 32'd0; next_perm = 3'd0; next_dirty = 1'b0;
    for (int w = 0; w < TLB_WAYS; w++) begin
      ix = slot_of(set, w);
      if (IS_D && !next_hit && tlb_val[ix] && (tlb_vpn[ix] == next_lin[31:12])) begin
        next_hit = 1'b1;
        next_phys = tlb_big[ix] ? {tlb_pfn[ix][19:10], next_lin[21:0]}
                                : {tlb_pfn[ix], next_lin[11:0]};
        next_perm = tlb_perm[ix]; next_dirty = tlb_dirty[ix];
      end
    end
  end
`endif
`ifdef VEN_P54_DUAL_HIT
  // The V packet has its own pre-fill lookup. Keep all payload fields from one
  // matching way; independently varying U/next addresses must not steer it.
  always_comb begin : pair_lookup_comb
    logic [SET_BITS-1:0] set;
    int ix;
    set = tlb_set(pair_lin);
    pair_hit = 1'b0;
    pair_phys = 32'd0;
    pair_perm = 3'd0;
    pair_dirty = 1'b0;
    for (int w = 0; w < TLB_WAYS; w++) begin
      ix = slot_of(set, w);
      if (IS_D && !pair_hit && tlb_val[ix] &&
          (tlb_vpn[ix] == pair_lin[31:12])) begin
        pair_hit = 1'b1;
        pair_phys = tlb_big[ix] ? {tlb_pfn[ix][19:10], pair_lin[21:0]}
                                 : {tlb_pfn[ix], pair_lin[11:0]};
        pair_perm = tlb_perm[ix];
        pair_dirty = tlb_dirty[ix];
      end
    end
  end
`endif

  // Reset > flush > fill is intentionally the same one-write-port priority as
  // tlb.sv.  A fill of an already resident VPN MUST update that exact way: the
  // D-side clean-to-dirty walk otherwise leaves a clean duplicate that can win
  // a later lookup and repeatedly re-walk (or expose stale permission/PFN data).
  always_ff @(posedge clk) begin : write_port
    if (!rst_n) begin
      for (int t = 0; t < TLB_ENTRIES; t++) begin
        tlb_val[t]   <= 1'b0;
        tlb_vpn[t]   <= 20'd0;
        tlb_pfn[t]   <= 20'd0;
        tlb_perm[t]  <= 3'd0;
        tlb_big[t]   <= 1'b0;
        tlb_dirty[t] <= 1'b0;
      end
      for (int s = 0; s < TLB_SETS; s++) rr_way[s] <= '0;
    end else if (flush_en) begin
      // Like tlb.sv, architectural invalidation only clears valid bits.  Tags
      // and payloads stay stale-by-design behind val, while rr state remains a
      // replacement policy detail rather than architectural state.
      for (int t = 0; t < TLB_ENTRIES; t++) tlb_val[t] <= 1'b0;
    end else if (fill_en) begin
      logic [SET_BITS-1:0] set;
      int fill_ix;
      int fill_way;
      int scan_ix;
      bit found_same;
      bit found_invalid;

      set           = tlb_set(fill_lin);
      fill_ix       = slot_of(set, int'(rr_way[set]));
      fill_way      = int'(rr_way[set]);
      found_same    = 1'b0;
      found_invalid = 1'b0;

      // Matching tag has priority over an invalid slot; otherwise a dirty
      // rewalk could allocate a duplicate despite another way being empty.
      for (int w = 0; w < TLB_WAYS; w++) begin
        scan_ix = slot_of(set, w);
        if (!found_same && tlb_val[scan_ix] &&
            (tlb_vpn[scan_ix] == fill_lin[31:12])) begin
          fill_ix    = scan_ix;
          fill_way   = w;
          found_same = 1'b1;
        end
      end
      if (!found_same) begin
        for (int w = 0; w < TLB_WAYS; w++) begin
          scan_ix = slot_of(set, w);
          if (!found_invalid && !tlb_val[scan_ix]) begin
            fill_ix       = scan_ix;
            fill_way      = w;
            found_invalid = 1'b1;
          end
        end
      end

      tlb_val[fill_ix]   <= 1'b1;
      tlb_vpn[fill_ix]   <= fill_lin[31:12];
      tlb_pfn[fill_ix]   <= fill_pfn;
      tlb_perm[fill_ix]  <= fill_perm;
      tlb_big[fill_ix]   <= fill_big;
      tlb_dirty[fill_ix] <= IS_D ? fill_dirty : 1'b0;

      if (!found_same) begin
        if (fill_way == (TLB_WAYS - 1)) rr_way[set] <= '0;
        else                            rr_way[set] <= WAY_BITS'(fill_way + 1);
      end
    end
  end

`ifndef SYNTHESIS
  // A duplicate valid tag within one set is never a legal result of the fill
  // policy.  This samples pre-NBA state, so a bad same-edge fill is reported
  // on the next clock; it is deliberately an assertion rather than a repair.
  always_ff @(posedge clk) begin : no_duplicate_tags
    if (rst_n) begin
      for (int s = 0; s < TLB_SETS; s++) begin
        for (int a = 0; a < TLB_WAYS; a++) begin
          for (int b = a + 1; b < TLB_WAYS; b++) begin
            assert (!(tlb_val[slot_of(SET_BITS'(s), a)] &&
                      tlb_val[slot_of(SET_BITS'(s), b)] &&
                      (tlb_vpn[slot_of(SET_BITS'(s), a)] ==
                       tlb_vpn[slot_of(SET_BITS'(s), b)])))
              else $error("tlb_assoc duplicate valid tags in set %0d", s);
          end
        end
      end
    end
  end
`endif

endmodule : tlb_assoc
