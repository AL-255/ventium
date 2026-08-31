`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/uopcache.sv — PREDECODED micro-op cache (predecode-on-fill).  [+VEN_UOPCACHE]
//
// The architectural Fmax wall (fpga/TIMING_PROBLEMS.md P0-7..P0-10) is the
// single-cycle x86 byte-window decoder: every clock the spine combinationally
// aligns a ~12-byte window (6 U bytes at flin, 6 V bytes at flin+lenU) out of a
// 256-bit icache line at ANY byte offset = twelve 32:1 byte selects (core.sv
// ub[]/vb[] gather, ~14.5K MUXF7 / 6.2K MUXF8, level-5 routing congestion).
// Relocating it (BRAM P0-3, decode-pipe P0-10) CONSERVES the MUXF; only deleting
// it at the source moves the wall. This is the textbook P6/Sandy-Bridge µop cache.
//
// The user's P5-decode insight maps here exactly: the original Pentium predecodes
// at ~1 byte/cycle and pipelines the variable-length (SIB) length decode, so the
// fast path never pays the alignment cost. We do the same: run the SAME pure
// `decode` leaf (core/decode.sv, 6 bytes -> fpd_t) on the MULTI-CYCLE line fill,
// walking instruction boundaries, and store fixed-width fpd_t entries indexed by
// SLOT (not byte offset). The fast path then reads u_d = slots[slot(flin)] and
// v_d = slots[slot+1] through a small ~8:1 slot mux — and because predecode chains
// the boundaries, V is literally U's NEXT slot, so the data-dependent flin+lenU
// V-base serialization disappears too. The twelve 32:1 byte selects are gone.
//
// Bit-exactness is STRUCTURAL: the SAME `decode` function produces the SAME fpd_t;
// we only move WHERE/WHEN it runs (fill walker, registered) and HOW it's indexed
// (slot, not byte). A parallel equivalence gate (+VEN_UOPCACHE_CHECK) asserts
// slots[slot(flin)] == the live ub/vb-gather decode for every issued flin.
//
// THE WALKER NEVER REINTRODUCES A WIDE BYTE MUX: it decodes a FIXED bottom-6-byte
// slice of a `residual` register and SHIFTS the residual right by the decoded
// length each cycle (a small <=48-bit barrel shift), so there is no flin-indexed
// 32:1 select anywhere — that is the whole point.
//
// STORE: per (set,way) an eight-entry base bank plus a four-entry tail bank of
// packed fpd_t, and a 32-entry byte->slot map ({valid,bank,slot[2:0]}). The split
// matters: a dense line needs more than eight decoded boundaries, but widening the
// fetch-path selector into a monolithic 12:1/16:1 mux would worsen its critical
// path. The spine keeps the proven 8:1 base selector and uses one bank bit to select
// the compact tail. Registered (synchronous) reads infer BRAM/URAM (the 64 idle
// URAMs) rather than a distributed-RAM read mux — mirrors the +VEN_IC_BRAM
// registered-line front-end timing exactly (valid the clock AFTER the address),
// replicated A/B for the two fetch-window lines. A still-denser line safely leaves
// its tail map entries invalid and re-predecodes from that flin (a performance event,
// never a correctness one).

module uopcache
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
#(
    parameter int IC_SETS = 128,
    parameter int IC_LINE = 32,
    parameter int BASE_SLOTS = 8,    // preserves the shallow base-bank selector
    parameter int TAIL_SLOTS = 4,    // dense-line coverage, selected by a bank bit
    parameter int IC_IDXW = $clog2(IC_SETS)  // set-index width (7 full / 6 half)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- registered slot-read ports (mirror icache rd_lineA/rd_lineB timing:
    // present (set,way) on clock T, the slot line + byte->slot map are valid on
    // T+1).  Port A = flin's line; port B = the next (straddle) line.
    input  logic [IC_IDXW-1:0]  rd_setA,
    input  logic        rd_wayA,
    output fpd_t        rd_baseA [BASE_SLOTS],
    output fpd_t        rd_tailA [TAIL_SLOTS],
    output logic        rd_bvalidA [IC_LINE],   // byte-offset is an insn boundary
    output logic [3:0]  rd_bslotA  [IC_LINE],   // ...and maps to {bank,slot[2:0]}
    output logic        rd_pdvalidA,            // this line has been predecoded
    input  logic [IC_IDXW-1:0]  rd_setB,
    input  logic        rd_wayB,
    output fpd_t        rd_baseB [BASE_SLOTS],
    output fpd_t        rd_tailB [TAIL_SLOTS],
    output logic        rd_bvalidB [IC_LINE],
    output logic [3:0]  rd_bslotB  [IC_LINE],
    output logic        rd_pdvalidB,

    // ---- predecode trigger: the spine pulses pd_start with the freshly-filled
    // 256-bit line (assembled from the S_PF burst) + its (set,way) + the EFLAGS /
    // cycle_mode the `decode` leaf needs (matches u_decode/v_decode inputs).
    input  logic         pd_start,
    input  logic [IC_IDXW-1:0]   pd_set,
    input  logic         pd_way,
    input  logic [IC_LINE*8-1:0] pd_line,
    input  logic [31:0]  pd_flags,
    input  logic         pd_cycle_mode,
    // REVIEW Aug-1 H-04: the DEFAULT OPERAND/ADDRESS SIZE the line was walked under.
    // The three live decoders in core.sv all receive .def16; this one did not, so the
    // walker decoded every line as 32-bit. With +VEN_UOPCACHE plus system fast mode a
    // 16-bit line was walked with the wrong default: wrong instruction LENGTHS, hence
    // wrong boundaries, hence a whole line of wrong slots and a corrupt byte->slot map.
    input  logic         pd_def16,
    // invalidate a (set,way)'s predecode validity (refill/SMC) — the spine pulses
    // this on allocate so a stale predecode never reads back valid.
    // REVIEW2 H-16: global predecode flush requested from outside (the I-cache is
    // being flushed wholesale because a PHYSICAL DMA snoop cannot be matched against
    // its LINEAR tags). Without this the I-cache would refill correct bytes while the
    // uop cache kept serving predecoded uops built from the STALE ones -- a worse
    // failure than the one being fixed, because the bytes would look right.
    input  logic         flush_all,
    input  logic         inv_en,
    input  logic [IC_IDXW-1:0]   inv_set,
    input  logic         inv_way,
    // R2-H09: a SECOND per-line invalidate (the icache's CPU-store snoop can
    // match two lines in one clock -- a line-crossing store snoops both).
    // Identical semantics to inv_*; either or both may fire.
    input  logic         inv2_en,
    input  logic [IC_IDXW-1:0]   inv2_set,
    input  logic         inv2_way,
    // REVIEW Aug-1 H-04: the CURRENT default size. A line predecoded under one default
    // must never be READ BACK under the other, so any change to it invalidates every
    // predecoded line. CS.D changes are rare (mode switches / far transfers), so this
    // costs a re-walk at a boundary the pipeline is already flushing.
    input  logic         cur_def16,
    output logic         pd_busy
);

  localparam int FPDW  = $bits(fpd_t);
  localparam int NSLOT = BASE_SLOTS + TAIL_SLOTS;
  localparam logic [3:0] LAST_SLOT = 4'(NSLOT-1);

  // ---- predecoded store: base + tail fpd_t banks per (set,way), a five-bit
  // byte-boundary map, and a per-line predecoded-valid bit. Registered reads (below)
  // infer block RAM, NOT a distributed-RAM read mux. The A/B copies are written
  // identically (one fill predecode writes both) so the two registered read ports are
  // each a single-read SDP RAM — same trick as ic_line_a/b.
  (* ram_style = "block" *) logic [BASE_SLOTS*FPDW-1:0] store_base_a [IC_SETS*2];
  (* ram_style = "block" *) logic [BASE_SLOTS*FPDW-1:0] store_base_b [IC_SETS*2];
  (* ram_style = "block" *) logic [TAIL_SLOTS*FPDW-1:0] store_tail_a [IC_SETS*2];
  (* ram_style = "block" *) logic [TAIL_SLOTS*FPDW-1:0] store_tail_b [IC_SETS*2];
  (* ram_style = "block" *) logic [IC_LINE*5-1:0]     store_bmap_a [IC_SETS*2]; // {valid,bank,slot[2:0]} x32
  (* ram_style = "block" *) logic [IC_LINE*5-1:0]     store_bmap_b [IC_SETS*2];
  logic store_pdv [IC_SETS*2];     // small: keep in FF

  // ---- registered reads (valid the clock AFTER the address) -----------------
  logic [BASE_SLOTS*FPDW-1:0] rdbase_a_q, rdbase_b_q;
  logic [TAIL_SLOTS*FPDW-1:0] rdtail_a_q, rdtail_b_q;
  logic [IC_LINE*5-1:0]      rdbmap_a_q, rdbmap_b_q;
  logic                  rdpdv_a_q,   rdpdv_b_q;
  // KV260 BRAM cross-port read-during-write collide flags (same hazard fixed in the
  // icache, commit 65c1929): the decoded banks and store_bmap arrays are block RAM; if a
  // slot read launches off rd_setA/rd_wayA the SAME cycle the walker W_WRITE writes that
  // set,way, the registered read is garbage on real RAMB36 (clean READ_FIRST under a
  // 2-state functional model). store_pdv is FF and invalidated on refill so it MOSTLY
  // gates this, but belt-and-suspenders: a collided read is forced not-predecoded-valid,
  // so the spine
  // re-walks (a perf event, never a wrong opcode). Behavior-neutral in 2-state sim.
  logic                  rd_collA_q,  rd_collB_q;
  // A fill/invalidate updates store_pdv at the SAME edge the registered read
  // samples its old value.  Without a returned-address invalidation guard, the
  // following S_PIPE clock can see the NEW I-cache line together with the OLD
  // line's predecode-valid bit and issue stale slots before the walker starts.
  // This is the invalidate analogue of the RAMB read-during-write guard below:
  // report the registered result as not-predecoded for that one stale cycle.
  logic                  rd_invA_q,   rd_invB_q;
`ifdef VEN_UOPCACHE_RDW_X
  // SIM-ONLY DECISIVE-CONFIRMATION MODEL (default OFF): emulate the real RAMB36
  // read-during-write collision the 2-state functional array model IDEALIZES away.
  // On silicon, a registered read that launches off {set,way} in the SAME cycle the
  // W_WRITE walker writes that exact {set,way} returns GARBAGE (not the clean OLD
  // value the array gives). We inject 'x into the slot/bmap registered read on that
  // collision so a sim that CONSUMES the slot read (cycle_mode=1 fast path) would
  // observe the corruption — and a sim that does NOT consume it (func mode) stays
  // bit-identical. If the board fetch #DE reproduces ONLY with this define -> the
  // uopcache RDW collision is the root cause; if it does NOT reproduce -> ruled out.
  function automatic logic [BASE_SLOTS*FPDW-1:0] rdw_x_base(input logic coll,
                                                             input logic [BASE_SLOTS*FPDW-1:0] clean);
    rdw_x_base = coll ? {BASE_SLOTS*FPDW{1'bx}} : clean;
  endfunction
  function automatic logic [TAIL_SLOTS*FPDW-1:0] rdw_x_tail(input logic coll,
                                                             input logic [TAIL_SLOTS*FPDW-1:0] clean);
    rdw_x_tail = coll ? {TAIL_SLOTS*FPDW{1'bx}} : clean;
  endfunction
  function automatic logic [IC_LINE*5-1:0] rdw_x_bmap(input logic coll,
                                                       input logic [IC_LINE*5-1:0] clean);
    rdw_x_bmap = coll ? {IC_LINE*5{1'bx}} : clean;
  endfunction
  logic collA_pre, collB_pre;
  always_comb begin
    collA_pre = (wst == W_WRITE) && ({rd_setA, rd_wayA} == {wset, wway});
    collB_pre = (wst == W_WRITE) && ({rd_setB, rd_wayB} == {wset, wway});
  end
`ifdef VEN_UOP_PERF
  // count the raw RDW collisions injected (proves the model is non-vacuous).
  longint unsigned rdwx_collA, rdwx_collB;
  always_ff @(posedge clk) if (rst_n) begin
    if (collA_pre) rdwx_collA <= rdwx_collA + 1;
    if (collB_pre) rdwx_collB <= rdwx_collB + 1;
  end
  final $display("[RDWX] uopcache RDW collisions: portA=%0d portB=%0d (x-injected slot reads)",
                 rdwx_collA, rdwx_collB);
`endif
`endif
  always_ff @(posedge clk) begin
`ifdef VEN_UOPCACHE_RDW_X
    rdbase_a_q  <= rdw_x_base(collA_pre, store_base_a[{rd_setA, rd_wayA}]);
    rdbase_b_q  <= rdw_x_base(collB_pre, store_base_b[{rd_setB, rd_wayB}]);
    rdtail_a_q  <= rdw_x_tail(collA_pre, store_tail_a[{rd_setA, rd_wayA}]);
    rdtail_b_q  <= rdw_x_tail(collB_pre, store_tail_b[{rd_setB, rd_wayB}]);
    rdbmap_a_q  <= rdw_x_bmap (collA_pre, store_bmap_a [{rd_setA, rd_wayA}]);
    rdbmap_b_q  <= rdw_x_bmap (collB_pre, store_bmap_b [{rd_setB, rd_wayB}]);
`else
    rdbase_a_q  <= store_base_a[{rd_setA, rd_wayA}];
    rdbase_b_q  <= store_base_b[{rd_setB, rd_wayB}];
    rdtail_a_q  <= store_tail_a[{rd_setA, rd_wayA}];
    rdtail_b_q  <= store_tail_b[{rd_setB, rd_wayB}];
    rdbmap_a_q  <= store_bmap_a [{rd_setA, rd_wayA}];
    rdbmap_b_q  <= store_bmap_b [{rd_setB, rd_wayB}];
`endif
    rdpdv_a_q   <= store_pdv[{rd_setA, rd_wayA}];
    rdpdv_b_q   <= store_pdv[{rd_setB, rd_wayB}];
    rd_collA_q  <= (wst == W_WRITE) && ({rd_setA, rd_wayA} == {wset, wway});
    rd_collB_q  <= (wst == W_WRITE) && ({rd_setB, rd_wayB} == {wset, wway});
    rd_invA_q   <= d16_flush
                || (inv_en  && ({rd_setA, rd_wayA} == {inv_set,  inv_way}))
                || (inv2_en && ({rd_setA, rd_wayA} == {inv2_set, inv2_way}));
    rd_invB_q   <= d16_flush
                || (inv_en  && ({rd_setB, rd_wayB} == {inv_set,  inv_way}))
                || (inv2_en && ({rd_setB, rd_wayB} == {inv2_set, inv2_way}));
  end

  // Unpack the registered banks and byte map. The fast path retains its 8:1 base
  // selector; the map's bank bit only selects the four-entry dense-line tail.
  always_comb begin
    for (int s=0;s<BASE_SLOTS;s++) begin
      rd_baseA[s] = rdbase_a_q[s*FPDW +: FPDW];
      rd_baseB[s] = rdbase_b_q[s*FPDW +: FPDW];
    end
    for (int s=0;s<TAIL_SLOTS;s++) begin
      rd_tailA[s] = rdtail_a_q[s*FPDW +: FPDW];
      rd_tailB[s] = rdtail_b_q[s*FPDW +: FPDW];
    end
    for (int b=0;b<IC_LINE;b++) begin
      rd_bvalidA[b] = rdbmap_a_q[b*5+4];
      rd_bslotA[b]  = rdbmap_a_q[b*5 +: 4];
      rd_bvalidB[b] = rdbmap_b_q[b*5+4];
      rd_bslotB[b]  = rdbmap_b_q[b*5 +: 4];
    end
    // a collided registered read holds BRAM-garbage on silicon — present it as
    // not-predecoded so the spine re-walks instead of issuing a garbage uop.
    rd_pdvalidA = rdpdv_a_q && !rd_collA_q && !rd_invA_q;
    rd_pdvalidB = rdpdv_b_q && !rd_collB_q && !rd_invB_q;
  end
`ifdef VEN_UOP_PERF
  // DIAGNOSTIC (sim-only, default OFF): confirm the uop cache POPULATES (pdv hits)
  // and the collide-guard is BENIGN (re-walks rare). hits = pdvalid presented;
  // rewalk = guard suppressed a valid-but-collided read (the only perf cost added).
  longint unsigned uop_hitA, uop_rewalkA;
  always_ff @(posedge clk) if (rst_n) begin
    if (rd_pdvalidA)             uop_hitA    <= uop_hitA + 1;
    if (rdpdv_a_q && rd_collA_q) uop_rewalkA <= uop_rewalkA + 1;
  end
  final $display("[UOPPERF] portA pdv-hits=%0d  guard-rewalks=%0d", uop_hitA, uop_rewalkA);
`endif

  // ---- predecode walker (sequential; ~1 instruction/cycle) -------------------
  // Decodes the FIXED bottom 6 bytes of `residual`, records the slot + boundary,
  // then shifts `residual` right by the decoded length (the only variable op, a
  // <=48-bit barrel shift) and advances the byte offset.  No flin-indexed wide
  // byte select anywhere — that is what keeps the alignment MUXF off the fabric.
  typedef enum logic [1:0] { W_IDLE, W_WALK, W_WRITE } wstate_e;
  wstate_e               wst;
  logic [IC_LINE*8-1:0]  residual;     // line, shifted as bytes are consumed
  logic [5:0]            woff;         // current byte offset within the line (0..32)
  logic [3:0]            wslot;        // current slot index
  logic [IC_IDXW-1:0]     wset; logic wway;
  logic [31:0]           wflags; logic wcyc; logic wd16;   // H-04: latched pd_def16
  // REVIEW2 H-14: the walk is a TRANSACTION and pd_start had no handshake.
  //  * A fill completing while the walker is busy was DROPPED entirely (the core
  //    ignores pd_busy and pulses pd_start for every completed I-cache fill), so the
  //    new line stayed un-predecoded -- a performance hole, and worse:
  //  * if that dropped fill targeted the SAME (set,way) the walker was working on,
  //    the old walk's final `store_pdv <= 1` at W_WRITE ran AFTER the new fill's
  //    inv_en had cleared it, RE-VALIDATING stale predecoded uops against freshly
  //    filled instruction bytes. That is the H-08/H-12 shape one level up.
  logic                  wpz;         // this walk was invalidated -> must not validate
  logic                  pd_pend;     // a start arrived while busy (1-deep skid)
  logic [IC_IDXW-1:0]    pd_pend_set; logic pd_pend_way;
  logic [IC_LINE*8-1:0]  pd_pend_line;
  logic [31:0]           pd_pend_flags; logic pd_pend_cyc, pd_pend_d16;
  logic                  pd_start_kill, pd_pend_kill;
  always_comb begin
    pd_start_kill = d16_flush
                 || (inv_en  && (inv_set  == pd_set) && (inv_way  == pd_way))
                 || (inv2_en && (inv2_set == pd_set) && (inv2_way == pd_way));
    pd_pend_kill  = pd_pend && (d16_flush
                 || (inv_en  && (inv_set  == pd_pend_set) && (inv_way  == pd_pend_way))
                 || (inv2_en && (inv2_set == pd_pend_set) && (inv2_way == pd_pend_way)));
  end

  // walker working buffers (written into the store on W_WRITE)
  logic [BASE_SLOTS*FPDW-1:0] wbuf_base;
  logic [TAIL_SLOTS*FPDW-1:0] wbuf_tail;
  logic [IC_LINE*5-1:0]      wbuf_bmap;

`ifdef VEN_UOP_PERF
  // Coverage accounting for the predecode walker.  A missing byte->slot entry
  // is intentionally safe (the spine uses S_FETCH), but its reason determines
  // whether a compact overflow structure is plausible or whether coverage is
  // fundamentally limited by instruction shape.  Sample only at W_WRITE, after
  // the final W_WALK update is visible; these counters have no datapath fanout.
  longint unsigned uop_walks, uop_walk_poison;
  longint unsigned uop_walk_slotcap, uop_walk_lineend, uop_walk_validsum;
  function automatic logic [5:0] uop_valid_boundaries(
      input logic [IC_LINE*5-1:0] bmap);
    uop_valid_boundaries = '0;
    for (int b=0; b<IC_LINE; b++)
      if (bmap[b*5+4]) uop_valid_boundaries = uop_valid_boundaries + 6'd1;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      uop_walks <= 0; uop_walk_poison <= 0;
      uop_walk_slotcap <= 0; uop_walk_lineend <= 0; uop_walk_validsum <= 0;
    end else if (wst == W_WRITE) begin
      uop_walks <= uop_walks + 1;
      if (wpz) uop_walk_poison <= uop_walk_poison + 1;
      // W_WALK increments wslot/woff before entering W_WRITE.  Equality is
      // therefore the exact stop condition, not a heuristic based on averages.
      if (wslot == 4'(NSLOT)) uop_walk_slotcap <= uop_walk_slotcap + 1;
      if (woff >= 6'(IC_LINE)) uop_walk_lineend <= uop_walk_lineend + 1;
      uop_walk_validsum <= uop_walk_validsum
                         + {{58{1'b0}}, uop_valid_boundaries(wbuf_bmap)};
    end
  end
  final $display("[UOPPERF] walks=%0d poisoned=%0d slot-cap=%0d line-end=%0d valid-boundaries=%0d",
                 uop_walks, uop_walk_poison, uop_walk_slotcap, uop_walk_lineend,
                 uop_walk_validsum);
`endif

  // the decode leaf, fed the FIXED bottom 6 bytes of residual (no mux).
  fpd_t pd_uop;
  decode u_pd_decode (
      .ib0(residual[7:0]),   .ib1(residual[15:8]),  .ib2(residual[23:16]),
      .ib3(residual[31:24]), .ib4(residual[39:32]), .ib5(residual[47:40]),
      .iflags(wflags), .def16(wd16), .cycle_mode(wcyc), .uop(pd_uop)
  );

  // decoded length, clamped to >=1 so the walk always advances (a non-simple op
  // still has len>=1 from decode.sv's default).  This is the byte-consume amount.
  logic [3:0] pd_len;
  assign pd_len = (pd_uop.len==4'd0) ? 4'd1 : pd_uop.len;

  assign pd_busy = (wst != W_IDLE);

  // REVIEW Aug-1 H-04: the default operand size every RESIDENT predecode was walked
  // under. When the live default changes (CS.D flip on a far transfer / mode switch)
  // every stored line's boundaries are wrong, so drop the whole predecode array.
  logic d16_q, d16_flush;
  // H-16: an external flush drops the whole predecode array by the same path as the
  // default-size change, so there is ONE global-clear mechanism rather than two.
  assign d16_flush = (cur_def16 != d16_q) || flush_all;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wst <= W_IDLE;
      d16_q <= 1'b0;
      wpz <= 1'b0; pd_pend <= 1'b0;   // H-14
      for (int i=0;i<IC_SETS*2;i++) store_pdv[i] <= 1'b0;
    end else begin
      d16_q <= cur_def16;
      // H-04: global predecode flush on a default-size change (takes priority over
      // the per-(set,way) invalidate below and over this fill's own validation).
      if (d16_flush)
        for (int i=0;i<IC_SETS*2;i++) store_pdv[i] <= 1'b0;
      // invalidate (refill/SMC): clear predecoded-valid for the (set,way).
      if (inv_en) store_pdv[{inv_set,inv_way}] <= 1'b0;
      if (inv2_en) store_pdv[{inv2_set,inv2_way}] <= 1'b0;   // R2-H09
      // H-14: if that invalidation (or a global d16 flush) hits the line THIS WALK is
      // building, the walk's result is stale before it is even written -- poison it so
      // W_WRITE does not resurrect it.
      if ((wst != W_IDLE) &&
          (d16_flush || (inv_en && (inv_set == wset) && (inv_way == wway))
          // R2-H09: the second invalidate poisons an in-flight walk the same way
          || (inv2_en && (inv2_set == wset) && (inv2_way == wway))))
        wpz <= 1'b1;
      // A queued walk is just as stale as the active one when its line is
      // invalidated.  Cancel it before it can later resurrect predecode data.
      if (pd_pend_kill) pd_pend <= 1'b0;
      // H-14: a start arriving while the walker is busy used to be dropped on the
      // floor. Hold it (1-deep) and run it when the walker goes idle. Deeper queueing
      // is unnecessary: starts are one per I-cache line fill, which cannot outrun the
      // walk by more than one in this design -- and if that ever changes, the
      // simulation warning below says so instead of silently losing predecode.
      if (pd_start && !pd_start_kill && (wst != W_IDLE)) begin
`ifndef SYNTHESIS
        if (pd_pend && !pd_pend_kill)
          $display("[UOPC] WARNING: second pd_start while one is pending (new set %0d way %0d dropped) -- REVIEW2 H-14 skid is 1-deep",
                   pd_set, pd_way);
`endif
        // Preserve the older queued request.  The old code claimed the new
        // request was dropped but actually overwrote the pending entry.
        if (!pd_pend || pd_pend_kill) begin
          pd_pend       <= 1'b1;
          pd_pend_set   <= pd_set;   pd_pend_way <= pd_way;
          pd_pend_line  <= pd_line;
          pd_pend_flags <= pd_flags; pd_pend_cyc <= pd_cycle_mode; pd_pend_d16 <= pd_def16;
        end
      end

      unique case (wst)
        W_IDLE: begin
          // H-14 scheduler: when a held request and a new fill arrive together,
          // launch the HELD request and replace the one-deep queue with the new
          // one.  The old code let the fresh request launch but left the held
          // request asserted; after the fresh walk wrote its line, that stale
          // request could run and revalidate predecode data for an evicted
          // {set,way}.  This is a real correctness issue, not just a dropped
          // predecode/performance event.  FIFO handoff preserves both requests
          // without adding storage or touching the fast path.
          if ((pd_pend && !pd_pend_kill) || (pd_start && !pd_start_kill)) begin
            residual   <= (pd_pend && !pd_pend_kill) ? pd_pend_line   : pd_line;
            woff       <= 6'd0;
            wslot      <= 4'd0;
            wset       <= (pd_pend && !pd_pend_kill) ? pd_pend_set    : pd_set;
            wway       <= (pd_pend && !pd_pend_kill) ? pd_pend_way    : pd_way;
            wflags     <= (pd_pend && !pd_pend_kill) ? pd_pend_flags  : pd_flags;
            wcyc       <= (pd_pend && !pd_pend_kill) ? pd_pend_cyc    : pd_cycle_mode;
            wd16       <= (pd_pend && !pd_pend_kill) ? pd_pend_d16    : pd_def16;
            wbuf_base  <= '0;
            wbuf_tail  <= '0;
            wbuf_bmap  <= '0;
            wpz        <= 1'b0;      // fresh transaction
            wst        <= W_WALK;
            if (pd_pend && !pd_pend_kill) begin
              if (pd_start && !pd_start_kill) begin
                pd_pend       <= 1'b1;
                pd_pend_set   <= pd_set;   pd_pend_way <= pd_way;
                pd_pend_line  <= pd_line;
                pd_pend_flags <= pd_flags; pd_pend_cyc <= pd_cycle_mode; pd_pend_d16 <= pd_def16;
              end else begin
                pd_pend <= 1'b0;   // consumed the held one
              end
            end
          end
        end
        W_WALK: begin
          // record this instruction's slot + its start-byte boundary, then consume.
          // The base bank is deliberately fixed at eight entries, so bit 3 is
          // both the bank select stored in the map and the walker bank select.
          // The tail's low two bits then address its four shallow entries.
          if (!wslot[3])
            wbuf_base[wslot*FPDW +: FPDW] <= pd_uop;
          else
            wbuf_tail[wslot[1:0]*FPDW +: FPDW] <= pd_uop;
          // boundary map: byte woff starts slot wslot (valid bit + slot index).
          // ONLY record a VALID boundary when the full six-byte decoder window
          // fits within this 32-byte line.  Checking only `woff+pd_len` is NOT
          // sufficient: at offset 31, for example, a Jcc's absent displacement
          // is zero-padded and can be misdecoded as a one-byte opcode, making
          // the bogus length appear to fit.  The walker deliberately has no
          // next-line input, so any tail window shorter than six bytes is
          // conservatively re-decoded by the spine from the real resident lines.
          // That loses at most five bytes of predecode coverage per line, never
          // executes an incomplete operand, and leaves the timing-critical fast
          // path unchanged.
          // ...AND only when the instruction FITS ENTIRELY within the 6-byte
          // decode window (pd_len <= 6). The decode leaf (u_pd_decode) is fed the
          // FIXED bottom 6 bytes of `residual`; an instruction with len>6 has
          // operand bytes (e.g. a far-jump ptr16:32 selector at bytes 6..7, or a
          // disp32+imm tail) that were NEVER presented to the leaf, so its fpd_t
          // (imm[31:0] et al) is UNRELIABLE — the same "bytes weren't seen" hazard
          // as the line-straddle case above, one scale down. Leaving the boundary
          // INVALID routes it to the slow S_FETCH path, which re-fetches all bytes.
          if ((woff < 6'(IC_LINE)) && (woff + 6'd6 <= 6'(IC_LINE))
              && (woff + {2'd0, pd_len} <= 6'(IC_LINE))
              && (pd_len <= 4'd6))
            wbuf_bmap[woff*5 +: 5] <= {1'b1, wslot[3], wslot[2:0]};
          residual <= residual >> {pd_len, 3'b000};   // drop pd_len bytes
          woff     <= woff + {2'd0, pd_len};
          wslot    <= wslot + 4'd1;
          // stop when the line is consumed or the slot capacity is reached.  A
          // boundary at/after byte 32 belongs to the NEXT line; capacity overflow
          // leaves the remaining bytes' map entries .valid=0 (spine re-predecodes).
          if ((woff + {2'd0, pd_len} >= IC_LINE) || (wslot == LAST_SLOT))
            wst <= W_WRITE;
        end
        W_WRITE: begin
          store_base_a [{wset,wway}] <= wbuf_base;
          store_base_b [{wset,wway}] <= wbuf_base;
          store_tail_a [{wset,wway}] <= wbuf_tail;
          store_tail_b [{wset,wway}] <= wbuf_tail;
          store_bmap_a [{wset,wway}] <= wbuf_bmap;
          store_bmap_b [{wset,wway}] <= wbuf_bmap;
          // H-04: a walk that started under the OLD default size must not validate.
          // This assignment is textually last, so it would otherwise override the
          // global flush above for this one line.
          // H-14: also refuse to validate a walk that was invalidated mid-flight.
          store_pdv[{wset,wway}]     <= !(wpz || d16_flush || (wd16 != cur_def16)
                                        || (inv_en && (inv_set==wset) && (inv_way==wway))
                                        // R2-H09: the second invalidate, same refusal
                                        || (inv2_en && (inv2_set==wset) && (inv2_way==wway)));
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

endmodule : uopcache
