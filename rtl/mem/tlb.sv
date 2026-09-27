`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/tlb.sv — split I/D TLB array + lookup + fill-commit + flush
//              (extracted from core.sv, R2; behaviour-preserving).
//
// PLAN.md §6.4 (Address generation) / docs/m2s2-paging-spec.md §3: a 16-entry,
// DIRECT-MAPPED TLB indexed by lin[15:12], one instance per side (itlb IS_D=0,
// dtlb IS_D=1). The data side additionally tracks the Dirty bit so a first write
// to a clean page re-walks to set D. This is the correctness model (NOT cycle
// timing): the whole S_WALK 2-level page-table micro-sequence — PDE/PTE reads,
// A/D writeback, #PF decision/CR2/error-code, the walk launch — STAYS in the
// spine; this module holds only the ARRAYS + the combinational lookup + the
// pulsed fill-commit + the pulsed CR3 flush.
//
// Behaviour-preserving extraction (R2): the inline itlb_*/dtlb_* arrays, the
// pure-comb itlb_hit/itlb_phys/dtlb_hit/dtlb_phys lookups, the tlb_fill_4k /
// tlb_fill_big mutating tasks, the CR3-flush val-clear, and the synchronous
// reset loop were lifted out of core.sv VERBATIM. The lookup ports are
// COMBINATIONAL off the REGISTERED arrays, so they reflect PRE-fill state in the
// same clock a posedge fill updates them (the tlb-lookup-vs-next-edge-fill
// read-before-write that func diff cannot see). All writes land on posedge.
//
// SINGLE WRITE PORT (verified mutually exclusive): the arrays mutate on AT MOST
// one of three events per clock — reset, OR a CR3 flush (S_EXEC MOV CR3, val
// bits ONLY), OR exactly one fill (S_WALK, when walk_for_d==IS_D). S_WALK and
// the CR3 write are different FSM states; reset overrides both. Never concurrent.
//
// STALE-BY-DESIGN: the CR3 flush clears ONLY the val bits — vpn/pfn/perm/big/
// dirty are left STALE (a later fill overwrites them; val gates correctness).
//
// Geometry (VERBATIM): idx=lin[15:12]; 4 KiB phys = {pfn, lin[11:0]}; a 4 MiB
// big page stores pfn={pde[31:22],10'd0} and overlays lin[21:0] for the offset
// ({pfn[19:10], lin[21:0]}).

module tlb #(
    parameter bit IS_D = 0,                 // 0 = I-TLB (fetch), 1 = D-TLB (data)
    parameter int TLB_ENTRIES = 16          // direct-mapped; index = lin[15:12]
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- Combinational lookup: drive lk_lin with the access's linear address;
    // hit/phys/perm/dirty are read off the REGISTERED arrays, so they reflect the
    // PRE-fill state this clock (the fill below is applied on posedge, a true TLB
    // SM, not a combinational peek). Mirrors itlb_hit/itlb_phys and dtlb_hit/
    // dtlb_phys/dtlb_dirty[idx]/dtlb_perm[idx] EXACTLY. The spine drives lk_lin
    // from cur_lin; the bus post-translate (mem_xlate) reuses these same outputs
    // because cur_lin == the bus mem_addr in every translatable state (proven
    // verbatim across the FSM arms), so a single lookup port serves both.
    input  logic [31:0] lk_lin,
    output logic        lk_hit,
    output logic [31:0] lk_phys,
    output logic [2:0]  lk_perm,            // effective {US, RW, P}
    output logic        lk_dirty,           // D-TLB only (I-TLB: always 0)
`ifdef VEN_PIPE_MEM_CHAIN
    // Read-only lookahead query; shares entries, never walks/touches/replaces.
    input  logic [31:0] next_lin,
    output logic        next_hit,
    output logic [31:0] next_phys,
    output logic [2:0]  next_perm,
    output logic        next_dirty,
`endif

    // ---- Pulsed fill-commit (from S_WALK ONLY, gated walk_for_d==IS_D in the
    // spine): when fill_en is high at a posedge, commit one entry for fill_lin.
    // fill_big selects the 4 MiB-page form (pfn/offset overlay); fill_dirty is
    // the D-side Dirty bit (is_w for 4 KiB, pde[6] for 4 MiB). Mirrors the
    // tlb_fill_4k / tlb_fill_big tasks (the operand AND/forcing is done in the
    // spine; this commits the already-computed pfn/perm). At most ONE fill/clock.
    input  logic        fill_en,
    input  logic [31:0] fill_lin,
    input  logic [19:0] fill_pfn,           // 4 KiB: pte[31:12]; 4 MiB: {pde[31:22],10'd0}
    input  logic [2:0]  fill_perm,          // effective {US, RW, P}
    input  logic        fill_big,           // 1 = 4 MiB page
    input  logic        fill_dirty,         // D-side Dirty (4 KiB: is_w; 4 MiB: pde[6])

    // ---- Pulsed flush (CR3 write): clears ONLY the val bits (vpn/pfn/perm/big/
    // dirty left STALE — IA-32 §4.10 MOV CR3 invalidates non-global entries).
    input  logic        flush_en
);

  logic        tlb_val   [TLB_ENTRIES];
  logic [19:0] tlb_vpn   [TLB_ENTRIES];   // linear page number lin[31:12]
  logic [19:0] tlb_pfn   [TLB_ENTRIES];   // physical frame phys[31:12]
  logic [2:0]  tlb_perm  [TLB_ENTRIES];   // {US, RW, P} effective
  logic        tlb_big   [TLB_ENTRIES];   // 1 = 4 MiB page
  logic        tlb_dirty [TLB_ENTRIES];   // D-TLB only: page already marked D in mem

  // Direct-mapped index from a linear address (lin[15:12]) — VERBATIM tlb_idx().
  function automatic logic [3:0] tlb_idx(input logic [31:0] lin);
    tlb_idx = lin[15:12];
  endfunction

  // Lookup body (pure-comb off the registered arrays; does NOT mutate state).
  // VERBATIM from the inline {i,d}tlb_hit / {i,d}tlb_phys functions.
  function automatic logic hit_of(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      hit_of = tlb_val[ix] && (tlb_vpn[ix] == lin[31:12]);
    end
  endfunction
  // 4 MiB page uses lin[21:0] offset (pfn low 10 bits forced 0 at fill), else
  // 4 KiB lin[11:0].
  function automatic logic [31:0] phys_of(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      phys_of = tlb_big[ix] ? {tlb_pfn[ix][19:10], lin[21:0]}
                            : {tlb_pfn[ix],          lin[11:0]};
    end
  endfunction

  always_comb begin
    logic [3:0] ix;
    ix       = tlb_idx(lk_lin);
    lk_hit   = hit_of(lk_lin);
    lk_phys  = phys_of(lk_lin);
    lk_perm  = tlb_perm[ix];
    lk_dirty = tlb_dirty[ix];
  end

`ifdef VEN_PIPE_MEM_CHAIN
  always_comb begin
    next_hit = IS_D && hit_of(next_lin);
    next_phys = phys_of(next_lin);
    next_perm = tlb_perm[tlb_idx(next_lin)];
    next_dirty = IS_D && tlb_dirty[tlb_idx(next_lin)];
  end
`endif

  // Fill-commit / CR3-flush / reset — the SINGLE write port. Mutually exclusive
  // by construction (reset || flush(S_EXEC) || fill(S_WALK), never concurrent).
  // The fill commits the spine-computed pfn/perm (the PDE&PTE AND and the 4 MiB
  // pfn-forcing are done in the spine, exactly as the old tlb_fill_* tasks did).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // M2S.2 paging: TLB empty out of reset (VERBATIM reset loop).
      for (int t=0;t<TLB_ENTRIES;t++) begin
        tlb_val[t]<=1'b0; tlb_vpn[t]<=20'd0; tlb_pfn[t]<=20'd0;
        tlb_perm[t]<=3'd0; tlb_big[t]<=1'b0; tlb_dirty[t]<=1'b0;
      end
    end else if (flush_en) begin
      // CR3 write: clear ONLY the val bits (vpn/pfn/perm/big/dirty left STALE).
      for (int t=0;t<TLB_ENTRIES;t++) tlb_val[t]<=1'b0;
    end else if (fill_en) begin
      logic [3:0] ix;
      ix = tlb_idx(fill_lin);
      tlb_val[ix]   <= 1'b1;             tlb_vpn[ix]   <= fill_lin[31:12];
      tlb_pfn[ix]   <= fill_pfn;         tlb_perm[ix]  <= fill_perm;
      tlb_big[ix]   <= fill_big;         tlb_dirty[ix] <= IS_D ? fill_dirty : 1'b0;
    end
  end

`ifndef SYNTHESIS
`ifdef VEN_TLB_PERF
  // Simulation-only replacement attribution.  Keep this beside the arrays so
  // a fill observes the PRE-NBA victim state, exactly as lookup does.  Nothing
  // here feeds a functional signal: it is deliberately excluded from synthesis
  // and does not add a port to the small standalone TLB testbench.
  longint unsigned tlbp_fill;
  longint unsigned tlbp_cold;
  longint unsigned tlbp_postflush;
  longint unsigned tlbp_invalid_other;
  longint unsigned tlbp_same_vpn;
  longint unsigned tlbp_conflict;
  longint unsigned tlbp_dirty_fill;
  longint unsigned tlbp_big_fill;
  longint unsigned tlbp_flush;
  longint unsigned tlbp_fill_idx          [TLB_ENTRIES];
  longint unsigned tlbp_cold_idx          [TLB_ENTRIES];
  longint unsigned tlbp_postflush_idx     [TLB_ENTRIES];
  longint unsigned tlbp_same_vpn_idx      [TLB_ENTRIES];
  longint unsigned tlbp_conflict_idx      [TLB_ENTRIES];
  logic            tlbp_ever_filled       [TLB_ENTRIES];
  logic            tlbp_flush_pending     [TLB_ENTRIES];
  logic            tlbp_first_conflict_v  [TLB_ENTRIES];
  logic [19:0]     tlbp_first_conflict_old[TLB_ENTRIES];
  logic [19:0]     tlbp_first_conflict_new[TLB_ENTRIES];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tlbp_fill          <= 0;
      tlbp_cold          <= 0;
      tlbp_postflush     <= 0;
      tlbp_invalid_other <= 0;
      tlbp_same_vpn      <= 0;
      tlbp_conflict      <= 0;
      tlbp_dirty_fill    <= 0;
      tlbp_big_fill      <= 0;
      tlbp_flush         <= 0;
      for (int t=0; t<TLB_ENTRIES; t++) begin
        tlbp_fill_idx[t]           <= 0;
        tlbp_cold_idx[t]           <= 0;
        tlbp_postflush_idx[t]      <= 0;
        tlbp_same_vpn_idx[t]       <= 0;
        tlbp_conflict_idx[t]       <= 0;
        tlbp_ever_filled[t]        <= 1'b0;
        tlbp_flush_pending[t]      <= 1'b0;
        tlbp_first_conflict_v[t]   <= 1'b0;
        tlbp_first_conflict_old[t] <= 20'd0;
        tlbp_first_conflict_new[t] <= 20'd0;
      end
    end else if (flush_en) begin
      // Mirror the functional writer's priority.  Only an actually valid slot
      // can later be classified as a refill caused by this flush; stale data
      // intentionally left behind by the architectural val-clear is not an
      // eviction and must not be counted as one.
      tlbp_flush <= tlbp_flush + 1;
      for (int t=0; t<TLB_ENTRIES; t++)
        if (tlb_val[t]) tlbp_flush_pending[t] <= 1'b1;
    end else if (fill_en) begin
      logic [3:0] ix;
      ix = tlb_idx(fill_lin);
      tlbp_fill         <= tlbp_fill + 1;
      tlbp_fill_idx[ix] <= tlbp_fill_idx[ix] + 1;
      if (!tlb_val[ix]) begin
        if (!tlbp_ever_filled[ix]) begin
          tlbp_cold          <= tlbp_cold + 1;
          tlbp_cold_idx[ix]  <= tlbp_cold_idx[ix] + 1;
        end else if (tlbp_flush_pending[ix]) begin
          tlbp_postflush         <= tlbp_postflush + 1;
          tlbp_postflush_idx[ix] <= tlbp_postflush_idx[ix] + 1;
        end else begin
          // No functional path invalidates one entry today.  Retain this
          // bucket so a future invalidation feature cannot masquerade as a
          // cold miss in profiling output.
          tlbp_invalid_other <= tlbp_invalid_other + 1;
        end
      end else if (tlb_vpn[ix] == fill_lin[31:12]) begin
        // On the D side this is normally the clean-to-dirty rewalk; retain the
        // neutral name because page-table edits may also legitimately refill
        // an existing linear page.
        tlbp_same_vpn         <= tlbp_same_vpn + 1;
        tlbp_same_vpn_idx[ix] <= tlbp_same_vpn_idx[ix] + 1;
      end else begin
        tlbp_conflict         <= tlbp_conflict + 1;
        tlbp_conflict_idx[ix] <= tlbp_conflict_idx[ix] + 1;
        if (!tlbp_first_conflict_v[ix]) begin
          tlbp_first_conflict_v[ix]   <= 1'b1;
          tlbp_first_conflict_old[ix] <= tlb_vpn[ix];
          tlbp_first_conflict_new[ix] <= fill_lin[31:12];
        end
      end
      if (IS_D && fill_dirty) tlbp_dirty_fill <= tlbp_dirty_fill + 1;
      if (fill_big)           tlbp_big_fill   <= tlbp_big_fill + 1;
      tlbp_ever_filled[ix]    <= 1'b1;
      tlbp_flush_pending[ix]  <= 1'b0;
    end
  end

  final begin
    $display("[TLBPERF:ARRAY] side=%0d fill=%0d cold=%0d postflush=%0d invalid-other=%0d same-vpn=%0d conflict=%0d dirty-fill=%0d big-fill=%0d flush=%0d",
             IS_D, tlbp_fill, tlbp_cold, tlbp_postflush, tlbp_invalid_other,
             tlbp_same_vpn, tlbp_conflict, tlbp_dirty_fill, tlbp_big_fill,
             tlbp_flush);
    for (int t=0; t<TLB_ENTRIES; t++)
      if (tlbp_fill_idx[t] != 0)
        $display("[TLBPERF:ARRAY] side=%0d idx=%0d fill=%0d cold=%0d postflush=%0d same-vpn=%0d conflict=%0d first-conflict=%05x->%05x",
                 IS_D, t, tlbp_fill_idx[t], tlbp_cold_idx[t],
                 tlbp_postflush_idx[t], tlbp_same_vpn_idx[t],
                 tlbp_conflict_idx[t], tlbp_first_conflict_old[t],
                 tlbp_first_conflict_new[t]);
  end
`endif
`endif

endmodule : tlb
