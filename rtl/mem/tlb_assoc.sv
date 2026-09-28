`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/tlb_assoc.sv -- bounded associative TLB experiment.
//
// This is deliberately a SEPARATE module from tlb.sv.  The deployed/default
// core continues to instantiate the 16-entry direct-map array verbatim; the
// core selects this module only under VEN_DTLB_ASSOC_2WAY,
// VEN_DTLB_ASSOC_4WAY, or VEN_ITLB_ASSOC_4WAY. That keeps an associative
// capacity experiment from perturbing the established baseline lookup or
// write-port semantics.
//
// The original experiment is D-only 16 sets x {2,4} ways. Its set selector is
// lin[15:12]; PSE fills retain the legacy 4 KiB-VPN key unless P54_LARGE is
// explicitly selected. That option keeps the 64-entry 4 KiB bank and adds the
// documented separate 8-entry (2-set x 4-way) 4 MiB data bank. The original
// default and 2-way behavior is preserved when the option is disabled.
//
// Replacement is invalid-way-first, then fill-only round robin.  It is NOT
// called P5 pseudo-LRU: the current core supplies an always-live lookup address
// rather than a qualified architectural touch, so mutating replacement state on
// raw hits would be wrong in idle/non-translatable states.  A later P5-fidelity
// step needs an explicit touch_en interface and its own tests.

module tlb_assoc #(
    parameter bit IS_D = 1,
    parameter int TLB_SETS = 16,
    parameter int TLB_WAYS = 2,
    // The P54C data TLB has a separate 2-set x 4-way large-page resource.
    // Default off preserves the existing 4 KiB-VPN-keyed experiment.
    parameter bit P54_LARGE = 0
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
  localparam int BIG_SETS    = 2;
  localparam int BIG_WAYS    = 4;
  localparam int BIG_ENTRIES = BIG_SETS * BIG_WAYS;

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

  // Four-megabyte data translations must not consume the 64 small-page slots.
  // Synthesis removes this bank entirely unless the P54 configuration selects
  // it. The 10-bit tag is the page number above the 22-bit page offset.
  logic        big_val   [BIG_ENTRIES];
  logic [9:0]  big_vpn   [BIG_ENTRIES];
  logic [9:0]  big_pfn   [BIG_ENTRIES];
  logic [2:0]  big_perm  [BIG_ENTRIES];
  logic        big_dirty [BIG_ENTRIES];
  logic [1:0]  big_rr_way [BIG_SETS];

  initial if (P54_LARGE && (!IS_D || TLB_SETS != 16 || TLB_WAYS != 4))
    $fatal(1, "P54 large-page D-TLB requires 16 sets x 4 ways");

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
    // If software remaps a 4 MiB region without invalidation and both banks
    // happen to match, the Pentium's large-page translation has priority.
    if (P54_LARGE && IS_D) begin
      for (int w = 0; w < BIG_WAYS; w++) begin
        ix = int'(lk_lin[22]) * BIG_WAYS + w;
        if (big_val[ix] && big_vpn[ix] == lk_lin[31:22]) begin
          lk_hit   = 1'b1;
          lk_phys  = {big_pfn[ix], lk_lin[21:0]};
          lk_perm  = big_perm[ix];
          lk_dirty = big_dirty[ix];
        end
      end
    end
  end

`ifdef VEN_PIPE_MEM_CHAIN
  // An independent side-effect-free translation read, including the optional
  // large-page bank. It does not allocate or mutate replacement state.
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
    if (P54_LARGE && IS_D) begin
      for (int w = 0; w < BIG_WAYS; w++) begin
        ix = int'(next_lin[22]) * BIG_WAYS + w;
        if (big_val[ix] && big_vpn[ix] == next_lin[31:22]) begin
          next_hit = 1'b1;
          next_phys = {big_pfn[ix], next_lin[21:0]};
          next_perm = big_perm[ix];
          next_dirty = big_dirty[ix];
        end
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
    if (P54_LARGE && IS_D) begin
      for (int w = 0; w < BIG_WAYS; w++) begin
        ix = int'(pair_lin[22]) * BIG_WAYS + w;
        if (big_val[ix] && big_vpn[ix] == pair_lin[31:22]) begin
          pair_hit = 1'b1;
          pair_phys = {big_pfn[ix], pair_lin[21:0]};
          pair_perm = big_perm[ix];
          pair_dirty = big_dirty[ix];
        end
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
      for (int t = 0; t < BIG_ENTRIES; t++) begin
        big_val[t] <= 1'b0;
        big_vpn[t] <= 10'd0;
        big_pfn[t] <= 10'd0;
        big_perm[t] <= 3'd0;
        big_dirty[t] <= 1'b0;
      end
      for (int s = 0; s < BIG_SETS; s++) big_rr_way[s] <= 2'd0;
    end else if (flush_en) begin
      // Like tlb.sv, architectural invalidation only clears valid bits.  Tags
      // and payloads stay stale-by-design behind val, while rr state remains a
      // replacement policy detail rather than architectural state.
      for (int t = 0; t < TLB_ENTRIES; t++) tlb_val[t] <= 1'b0;
      for (int t = 0; t < BIG_ENTRIES; t++) big_val[t] <= 1'b0;
    end else if (fill_en) begin
      if (P54_LARGE && IS_D && fill_big) begin : fill_large
        logic set;
        int fill_ix;
        int fill_way;
        int scan_ix;
        bit found_same;
        bit found_invalid;

        set = fill_lin[22];
        fill_ix = int'(set) * BIG_WAYS + int'(big_rr_way[set]);
        fill_way = int'(big_rr_way[set]);
        found_same = 1'b0;
        found_invalid = 1'b0;
        for (int w = 0; w < BIG_WAYS; w++) begin
          scan_ix = int'(set) * BIG_WAYS + w;
          if (!found_same && big_val[scan_ix] &&
              big_vpn[scan_ix] == fill_lin[31:22]) begin
            fill_ix = scan_ix;
            fill_way = w;
            found_same = 1'b1;
          end
        end
        if (!found_same) begin
          for (int w = 0; w < BIG_WAYS; w++) begin
            scan_ix = int'(set) * BIG_WAYS + w;
            if (!found_invalid && !big_val[scan_ix]) begin
              fill_ix = scan_ix;
              fill_way = w;
              found_invalid = 1'b1;
            end
          end
        end
        big_val[fill_ix] <= 1'b1;
        big_vpn[fill_ix] <= fill_lin[31:22];
        big_pfn[fill_ix] <= fill_pfn[19:10];
        big_perm[fill_ix] <= fill_perm;
        big_dirty[fill_ix] <= fill_dirty;
        if (!found_same) begin
          if (fill_way == BIG_WAYS - 1) big_rr_way[set] <= 2'd0;
          else                          big_rr_way[set] <= 2'(fill_way + 1);
        end
      end else begin : fill_small
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
      if (P54_LARGE && IS_D) begin
        for (int s = 0; s < BIG_SETS; s++) begin
          for (int a = 0; a < BIG_WAYS; a++) begin
            for (int b = a + 1; b < BIG_WAYS; b++) begin
              assert (!(big_val[s * BIG_WAYS + a] &&
                        big_val[s * BIG_WAYS + b] &&
                        big_vpn[s * BIG_WAYS + a] ==
                        big_vpn[s * BIG_WAYS + b]))
                else $error("tlb_assoc duplicate large-page tags in set %0d", s);
            end
          end
        end
      end
    end
  end
`endif

endmodule : tlb_assoc
