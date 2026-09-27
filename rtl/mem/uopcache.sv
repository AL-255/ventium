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
// THE WALKER NEVER REINTRODUCES A WIDE BYTE MUX: it decodes a FIXED bottom-7-byte
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
    parameter int IC_IDXW = $clog2(IC_SETS),  // set-index width (7 full / 6 half)
    // Experimental fill-side continuation.  With this clear (the production
    // default), the walker is bit-for-bit the original twelve-action service.
    // With it set, the published foreground prefix may be extended only while
    // no refill is waiting; the resident banks and fast read path stay fixed.
    parameter bit POSTPUBLISH_EXT = 1'b0,
    // Default-off, exact #UD scanner exception.  This does not add a map for
    // the faulting form; it merely permits the fill walker to continue past
    // FF /7 register encodings whose length is architecturally unambiguous.
    parameter bit RESYNC_FIXED_UD = 1'b0,
    // When set, a complete executable descriptor may be mapped at a physical
    // line tail even when the unused portion of the fixed decode window
    // would cross into the next line.  The descriptor itself must still end in
    // this line; a separate decoder-locality miter proves that the mapped fpd_t
    // cannot depend on those omitted suffix bytes.  Keep this off by default
    // until the whole-core acceptance ladder promotes it.
    parameter bit TAIL_LOCAL = 1'b0,
    // Optional execution-directed rebuild. Uses the idle fill walker and the
    // existing banks; a real refill preempts it on every cycle, even publication.
    parameter bit EXEC_REPAIR = 1'b0
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
    // Best-effort hint: caller proves the whole line's returned cache identity
    // and that repair_off is the current architectural instruction boundary.
    // No hint is queued. Accepted only on repair_ready; old metadata remains
    // usable until an atomically published replacement is ready.
    input  logic         repair_start,
    input  logic [IC_IDXW-1:0] repair_set,
    input  logic         repair_way,
    input  logic [IC_LINE*8-1:0] repair_line,
    input  logic [4:0]   repair_off,
    input  logic [31:0]  repair_flags,
    output logic         repair_ready,
`ifdef VEN_UOP_CROSSLINE
    // One optional cross-line descriptor, built by the SAME idle walker.
    // Caller supplies two simultaneously identity-checked resident lines.
    input logic          repair_next_valid,
    input logic [47:0]   repair_next_bytes,
    input logic [IC_IDXW-1:0] repair_next_set,
    input logic          repair_next_way,
    input logic [IC_IDXW-1:0] cross_query_set, cross_query_next_set,
    input logic          cross_query_way, cross_query_next_way,
    input logic [4:0]    cross_query_off,
    output logic         cross_hit,
    output fpd_t         cross_uop,
`endif
    output logic         pd_busy
);

  localparam int FPDW  = $bits(fpd_t);
  localparam int NSLOT = BASE_SLOTS + TAIL_SLOTS;
  // Count includes the full sentinel: sixteen entries need five count bits,
  // although the published {bank,slot} index remains four bits.
  localparam int SLOT_COUNT_W = $clog2(NSLOT + 1);
  localparam int TAIL_IDX_W = $clog2(TAIL_SLOTS);
  localparam logic [SLOT_COUNT_W-1:0] SLOT_LIMIT = SLOT_COUNT_W'(NSLOT);
  localparam logic [SLOT_COUNT_W-1:0] LAST_SLOT = SLOT_COUNT_W'(NSLOT-1);
  // Preserve the proven foreground/skid service bound when adding capacity.
  // Additional entries are filled only by the preemptible background walker.
  localparam logic [5:0] LAST_FG_STEP = 6'((NSLOT < 12) ? NSLOT-1 : 11);

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
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
  // Simulation-only provenance for a valid line's first uncovered boundary.
  // It is stored beside the fill metadata and sampled with the registered read
  // ports, so the core profiler can distinguish capacity/tail limits from a
  // fail-closed grammar stop without adding a hardware bit or read-side cone.
  localparam logic [2:0] UC_END_NONE    = 3'd0;
  localparam logic [2:0] UC_END_LINE    = 3'd1;
  localparam logic [2:0] UC_END_SLOT    = 3'd2;
  localparam logic [2:0] UC_END_STEP    = 3'd3;
  localparam logic [2:0] UC_END_UNKNOWN = 3'd4;
  localparam logic [2:0] UC_END_TAIL    = 3'd5;
  logic [2:0] store_end_reason [IC_SETS*2];
  // The first six residual bytes at the stop point.  This is deliberately
  // debug metadata rather than an extra cache field: core.sv uses it only to
  // correlate an uncovered executable boundary with the exact grammar that
  // made its fill walk stop.  It must never enter an admission decision.
  logic [47:0] store_end_bytes [IC_SETS*2];
`endif
`endif

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
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
  // Hierarchically visible only to core.sv's simulation-only profiler. These
  // follow rdpdv/bmap's exact T->T+1 request timing.
  logic [2:0]  rd_end_reasonA_q, rd_end_reasonB_q;
  logic [47:0] rd_end_bytesA_q,  rd_end_bytesB_q;
`endif
`endif
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
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
    rd_end_reasonA_q <= store_end_reason[{rd_setA, rd_wayA}];
    rd_end_reasonB_q <= store_end_reason[{rd_setB, rd_wayB}];
    rd_end_bytesA_q  <= store_end_bytes [{rd_setA, rd_wayA}];
    rd_end_bytesB_q  <= store_end_bytes [{rd_setB, rd_wayB}];
`endif
`endif
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
  // Decodes the FIXED bottom 7 bytes of `residual`, records the slot + boundary,
  // then shifts `residual` right by the decoded length (the only variable op, a
  // <=80-bit barrel shift for an audited slow-form skip) and advances the byte
  // offset.  No flin-indexed wide byte select anywhere — that is what keeps the
  // alignment MUXF off the fabric.
  typedef enum logic [2:0] { W_IDLE, W_WALK, W_WRITE, W_EXT, W_SEEK } wstate_e;
  wstate_e               wst;
`ifdef VEN_UOP_CROSSLINE
  // Six suffix bytes cover every <=7-byte instruction starting in this line.
  // W_SEEK still shifts one byte per cycle; no variable alignment mux is added.
  logic [IC_LINE*8+48-1:0] residual;
  logic cross_valid_q, cross_mode_q, wnext_valid, wnext_way;
  logic [IC_IDXW-1:0] cross_set_q, cross_next_set_q, wnext_set;
  logic cross_way_q, cross_next_way_q;
  logic [4:0] cross_off_q;
  logic cross_kill, wnext_kill;
  fpd_t cross_uop_q;
  logic cross_primary_hit;
`ifdef VEN_UOP_CROSS2
  // One victim descriptor, sharing the existing repair decoder and byte walk.
  // Both source identities are retained; no extra instruction-byte lookup.
  logic cross_victim_valid, cross_victim_mode, cross_victim_way, cross_victim_next_way;
  logic [IC_IDXW-1:0] cross_victim_set, cross_victim_next_set;
  logic [4:0] cross_victim_off;
  fpd_t cross_victim_uop;
  logic cross_victim_kill, cross_victim_hit;
`ifdef VEN_UOP_CROSS_INDEX
  // Indexed displaced descriptors: one lookup, not a parallel payload CAM.
  // Keep metadata separate so the payload has one write/read RAM port and
  // invalidations inspect only the small source-identity records.
  typedef struct packed {
    logic mode16, way, next_way;
    logic [IC_IDXW-1:0] set_id, next_set;
    logic [4:0] off;
  } cross_meta_t;
  logic [31:0] cross_index_valid;
  cross_meta_t cross_index_meta [32];
  (* ram_style = "distributed" *) fpd_t cross_index_data [32];
  logic [4:0] cross_read_index, cross_write_index;
  assign cross_read_index = 5'(cross_query_set);
  assign cross_write_index = 5'(cross_set_q);
  assign cross_victim_valid = cross_index_valid[cross_read_index];
  assign cross_victim_uop = cross_index_data[cross_read_index];
  assign cross_victim_mode = cross_index_meta[cross_read_index].mode16;
  assign cross_victim_way = cross_index_meta[cross_read_index].way;
  assign cross_victim_next_way = cross_index_meta[cross_read_index].next_way;
  assign cross_victim_set = cross_index_meta[cross_read_index].set_id;
  assign cross_victim_next_set = cross_index_meta[cross_read_index].next_set;
  assign cross_victim_off = cross_index_meta[cross_read_index].off;
`endif
  assign cross_victim_kill = d16_flush ||
      (inv_en && ((inv_set==cross_victim_set && inv_way==cross_victim_way) ||
                  (inv_set==cross_victim_next_set && inv_way==cross_victim_next_way))) ||
      (inv2_en && ((inv2_set==cross_victim_set && inv2_way==cross_victim_way) ||
                   (inv2_set==cross_victim_next_set && inv2_way==cross_victim_next_way)));
  assign cross_victim_hit = cross_victim_valid && cross_victim_mode==cur_def16 &&
      cross_query_set==cross_victim_set && cross_query_way==cross_victim_way &&
      cross_query_off==cross_victim_off && cross_query_next_set==cross_victim_next_set &&
      cross_query_next_way==cross_victim_next_way;
  assign cross_hit = cross_primary_hit || cross_victim_hit;
  assign cross_uop = cross_primary_hit ? cross_uop_q : cross_victim_uop;
`else
  assign cross_hit = cross_primary_hit;
  assign cross_uop = cross_uop_q;
`endif
  assign cross_kill = d16_flush ||
      (inv_en && ((inv_set==cross_set_q && inv_way==cross_way_q) ||
                  (inv_set==cross_next_set_q && inv_way==cross_next_way_q))) ||
      (inv2_en && ((inv2_set==cross_set_q && inv2_way==cross_way_q) ||
                   (inv2_set==cross_next_set_q && inv2_way==cross_next_way_q)));
  assign wnext_kill = wnext_valid &&
      ((inv_en && inv_set==wnext_set && inv_way==wnext_way) ||
       (inv2_en && inv2_set==wnext_set && inv2_way==wnext_way));
  // Match normal registered descriptor ports: CPU-store snoops originate
  // from the current instruction and must not feed back into its lookup.
  // Local invalidation clears validity at the edge; core exec_issue_ok fences
  // same-cycle global/DMA flush consumption independently of the descriptor.
  assign cross_primary_hit = cross_valid_q &&
      cross_mode_q==cur_def16 && cross_query_set==cross_set_q &&
      cross_query_way==cross_way_q && cross_query_off==cross_off_q &&
      cross_query_next_set==cross_next_set_q && cross_query_next_way==cross_next_way_q;
`else
  logic [IC_LINE*8-1:0]  residual;     // line, shifted as bytes are consumed
`endif
  logic [5:0]            woff;         // current byte offset within the line (0..32)
  logic [SLOT_COUNT_W-1:0] wslot;       // current slot index, or full sentinel
  // Service budget is independent of slot allocation. Known slow instructions
  // intentionally leave wslot unchanged, but the one-deep fill skid was proven
  // against the original <=12-cycle foreground service time. The wider counter
  // also reports an optional post-publish walk exactly through a 32-byte line.
  logic [5:0]            wsteps;
  logic                  wext_armed; // foreground stopped only at its step cap
  logic                  wext_dirty; // W_EXT added a visible map boundary
  logic                  wrepair;
  logic [4:0]            wanchor;
  // A loop with >NSLOT boundaries cannot fit at any anchor. Unrestricted
  // replacements rotate the map forever and regress such loops. After the
  // first repair, permit only an EARLIER anchor until the next foreground fill.
  // Six bits encode the initial sentinel 32. No reset/snoop write is necessary:
  // store_pdv fences old values, and foreground publication initializes them.
  (* ram_style = "distributed" *) logic [5:0] repair_floor [IC_SETS*2];
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
  logic                  pd_start_live, pd_pend_live;
`ifndef SYNTHESIS
  // A second start while the one-deep skid is occupied is architecturally
  // fail-safe (the fresh I-cache fill remains invalid and falls back to the
  // byte decoder), but it is still lost predecode work.  Keep an observable
  // counter so directed cadence tests and performance profiles never mistake
  // that fallback for a healthy producer/consumer handshake.
  longint unsigned       uop_skid_drop;
`endif
  always_comb begin
    pd_start_kill = d16_flush
                 || (inv_en  && (inv_set  == pd_set) && (inv_way  == pd_way))
                 || (inv2_en && (inv2_set == pd_set) && (inv2_way == pd_way));
    pd_pend_kill  = pd_pend && (d16_flush
                 || (inv_en  && (inv_set  == pd_pend_set) && (inv_way  == pd_pend_way))
                 || (inv2_en && (inv2_set == pd_pend_set) && (inv2_way == pd_pend_way)));
    pd_start_live = pd_start && !pd_start_kill;
    pd_pend_live  = pd_pend && !pd_pend_kill;
  end

  // walker working buffers (written into the store on W_WRITE)
  logic [BASE_SLOTS*FPDW-1:0] wbuf_base;
  logic [TAIL_SLOTS*FPDW-1:0] wbuf_tail;
  logic [IC_LINE*5-1:0]      wbuf_bmap;

`ifdef VEN_UOP_PERF
`ifndef SYNTHESIS
  // Coverage accounting for the predecode walker.  A missing byte->slot entry
  // is intentionally safe (the spine uses S_FETCH), but its reason determines
  // whether a compact overflow structure is plausible or whether coverage is
  // fundamentally limited by instruction shape.  Sample only at W_WRITE, after
  // the final W_WALK update is visible; these counters have no datapath fanout.
  longint unsigned uop_walks, uop_walk_poison;
  longint unsigned uop_walk_slotcap, uop_walk_stepcap, uop_walk_lineend, uop_walk_validsum;
  longint unsigned uop_walk_skip, uop_walk_stop, uop_walk_stop_unknown, uop_walk_stop_tail;
  longint unsigned uop_walk_stop_op [256], uop_walk_stop_0f [256];
  // One first sample per rejected first byte makes the aggregate stop histogram
  // actionable without putting a trace port or a simulator-only callback on the
  // fill path. `residual` is byte-0-first, so print it as a little-endian byte
  // window below rather than treating its hex rendering as instruction order.
  logic          uop_walk_stop_seen [256];
  logic [47:0]   uop_walk_stop_sample [256];
  logic [5:0]    uop_walk_stop_off [256];
  logic [5:0]    uop_walk_stop_steps [256];
  function automatic logic [5:0] uop_valid_boundaries(
      input logic [IC_LINE*5-1:0] bmap);
    uop_valid_boundaries = '0;
    for (int b=0; b<IC_LINE; b++)
      if (bmap[b*5+4]) uop_valid_boundaries = uop_valid_boundaries + 6'd1;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      uop_walks <= 0; uop_walk_poison <= 0;
      uop_walk_slotcap <= 0; uop_walk_stepcap <= 0;
      uop_walk_lineend <= 0; uop_walk_validsum <= 0;
      uop_walk_skip <= 0; uop_walk_stop <= 0;
      uop_walk_stop_unknown <= 0; uop_walk_stop_tail <= 0;
      for (int i=0;i<256;i++) begin
        uop_walk_stop_op[i] <= 0;
        uop_walk_stop_0f[i] <= 0;
        uop_walk_stop_seen[i] <= 1'b0;
        uop_walk_stop_sample[i] <= '0;
        uop_walk_stop_off[i] <= '0;
        uop_walk_stop_steps[i] <= '0;
      end
    end else begin
      if ((wst == W_WALK) && !pd_exec) begin
        if (scan_fits_line) uop_walk_skip <= uop_walk_skip + 1;
        else begin
          uop_walk_stop <= uop_walk_stop + 1;
          if (!scan_known) begin
            uop_walk_stop_unknown <= uop_walk_stop_unknown + 1;
            uop_walk_stop_op[residual[7:0]] <= uop_walk_stop_op[residual[7:0]] + 1;
            if (!uop_walk_stop_seen[residual[7:0]]) begin
              uop_walk_stop_seen[residual[7:0]] <= 1'b1;
              uop_walk_stop_sample[residual[7:0]] <= residual[47:0];
              uop_walk_stop_off[residual[7:0]] <= woff;
              uop_walk_stop_steps[residual[7:0]] <= wsteps;
            end
            if (residual[7:0] == 8'h0F)
              uop_walk_stop_0f[residual[15:8]] <= uop_walk_stop_0f[residual[15:8]] + 1;
          end else begin
            uop_walk_stop_tail <= uop_walk_stop_tail + 1;
          end
        end
      end
      if (wst == W_WRITE) begin
        uop_walks <= uop_walks + 1;
        if (wpz) uop_walk_poison <= uop_walk_poison + 1;
        // W_WALK increments wslot/woff before entering W_WRITE. Equality is
        // therefore the exact stop condition, not a heuristic based on averages.
        if (wslot == SLOT_LIMIT) uop_walk_slotcap <= uop_walk_slotcap + 1;
        if (wsteps == LAST_FG_STEP + 6'd1) uop_walk_stepcap <= uop_walk_stepcap + 1;
        if (woff >= 6'(IC_LINE)) uop_walk_lineend <= uop_walk_lineend + 1;
        uop_walk_validsum <= uop_walk_validsum
                           + {{58{1'b0}}, uop_valid_boundaries(wbuf_bmap)};
      end
    end
  end
  final $display("[UOPPERF] walks=%0d poisoned=%0d slot-cap=%0d step-cap=%0d line-end=%0d valid-boundaries=%0d",
                 uop_walks, uop_walk_poison, uop_walk_slotcap, uop_walk_stepcap,
                 uop_walk_lineend, uop_walk_validsum);
  final $display("[UOPPERF] nonexec known-skips=%0d fail-closed-stops=%0d",
                 uop_walk_skip, uop_walk_stop);
  final begin
    $display("[UOPPERF] fail-closed unknown=%0d line-tail=%0d", uop_walk_stop_unknown,
             uop_walk_stop_tail);
    for (int i=0;i<256;i++)
      if (uop_walk_stop_op[i] != 0)
        $display("[UOPPERF] stop byte=%02x count=%0d first-off=%0d step=%0d bytes=%02x %02x %02x %02x %02x %02x",
                 i, uop_walk_stop_op[i], uop_walk_stop_off[i], uop_walk_stop_steps[i],
                 uop_walk_stop_sample[i][7:0], uop_walk_stop_sample[i][15:8],
                 uop_walk_stop_sample[i][23:16], uop_walk_stop_sample[i][31:24],
                 uop_walk_stop_sample[i][39:32], uop_walk_stop_sample[i][47:40]);
    for (int i=0;i<256;i++)
      if (uop_walk_stop_0f[i] != 0)
        $display("[UOPPERF] stop 0f %02x count=%0d", i, uop_walk_stop_0f[i]);
  end
`endif
`endif

  // The decode leaf is fed the FIXED bottom seven bytes of residual (no mux).
  // Its default `simple=0,len=1` is an intentional fast-path fallback, NOT a
  // generic x86 length decoder. Only an executable fpd_t may consume a cache
  // slot; non-executable instructions use the bounded scanner below or stop.
  fpd_t pd_uop;
  decode u_pd_decode (
      .ib0(residual[7:0]),   .ib1(residual[15:8]),  .ib2(residual[23:16]),
      .ib3(residual[31:24]), .ib4(residual[39:32]), .ib5(residual[47:40]), .ib6(residual[55:48]),
      .iflags(wflags), .def16(wd16), .cycle_mode(wcyc), .uop(pd_uop)
  );

  // Decoded executable length, clamped to >=1. `pd_len` is deliberately used
  // only when pd_exec is true; the non-simple decode default is never consumed.
  logic [3:0] pd_len;
  assign pd_len = (pd_uop.len==4'd0) ? 4'd1 : pd_uop.len;
  // The cycle-mode FP whitelist carries its executable descriptor through
  // .is_fp while leaving .simple clear. Preserve that existing special case.
  logic pd_exec;
  assign pd_exec = pd_uop.simple || pd_uop.is_fp;

  // The original walker required the whole fixed decode window to be
  // local.  That is safely conservative, but loses an otherwise complete U
  // instruction near a 32-byte line tail.  Under TAIL_LOCAL, map based on the
  // actual descriptor extent instead.  Do not relax this to a cross-line
  // instruction: `<= IC_LINE` means its last byte is still local; `>` is
  // intentionally unmapped.  The core still retains its existing raw-byte
  // residency and tagged cross-line-V guards, so this predicate is fill-side
  // coverage only, never a cold-fetch or V-pairing shortcut.
  logic pd_map_fits;
  assign pd_map_fits = (woff < 6'(IC_LINE)) &&
                       (woff + {2'd0, pd_len} <= 6'(IC_LINE)) &&
                       (pd_len <= 4'd7) &&
                       (TAIL_LOCAL || (woff + 6'd6 <= 6'(IC_LINE)));

  // Fill-side-only, fail-closed scanner for a known slow instruction. It never
  // emits an fpd_t.  Nearly every known form also leaves its map entry fully
  // invalid; the sole exception is `scan_short_sfetch_safe`, an exact two-byte
  // REP MOVS/STOS descriptor carried in the unused payload of an invalid entry.
  // That descriptor remains non-executable and only lets the core's established
  // S_FETCH -> S_DECODE path avoid asking for unrelated suffix bytes.
  logic       scan_known, scan_fits_line, scan_short_sfetch_safe;
  logic       scan_slow_hint;
  // Invalid-map payload 1 means an exact bare FWAIT. Unlike the REP length-2
  // hint, it is NOT a shortened-fetch contract: it only suppresses futile
  // executable repair. The ordinary slow decoder still owns #NM/#MF.
  assign scan_slow_hint = scan_short_sfetch_safe
`ifdef VEN_UOP_FWAIT_HINT
                       || (scan_known && scan_len == 4'd1 && residual[7:0] == 8'h9b)
`endif
                       ;
  logic [3:0] scan_len;
  ven_predecode_len #(.RESYNC_FIXED_UD(RESYNC_FIXED_UD)) u_pd_scan (
      .bytes(residual[47:0]), .def16(wd16), .known(scan_known), .len(scan_len),
      .short_sfetch_safe(scan_short_sfetch_safe)
  );
  assign scan_fits_line = scan_known &&
                          (woff + {2'd0,scan_len} <= 6'(IC_LINE));

  assign pd_busy = (wst != W_IDLE);
`ifdef VEN_UOP_CROSSLINE
  logic cross_seek_yield;
`ifdef VEN_UOP_REPAIR_FAIR
  // A late cross-line seek may yield once to an earlier map repair, but a
  // recurring earlier anchor must not prevent every cross-line publication.
  // This bit protects the next late seek only; fills and invalidations still
  // have their normal priority and can discard the disposable repair.
  logic cross_yield_recent_q;
`endif
  // A cross-line attempt admitted ONLY by the optional floor exception must
  // not block the baseline's useful earlier-anchor map repairs. Both are
  // disposable; real fills retain their existing higher priority below.
  assign cross_seek_yield = EXEC_REPAIR && wrepair && wst==W_SEEK &&
      ({1'b0,wanchor} >= repair_floor[{wset,wway}]) && repair_start &&
`ifdef VEN_UOP_REPAIR_FAIR
      !(cross_yield_recent_q && wanchor > 5'd25) &&
`endif
      !pd_start_live && !pd_pend_live && !d16_flush &&
      store_pdv[{repair_set,repair_way}] &&
      ({1'b0,repair_off} < repair_floor[{repair_set,repair_way}]) &&
      !(inv_en && inv_set==repair_set && inv_way==repair_way) &&
      !(inv2_en && inv2_set==repair_set && inv2_way==repair_way);
`endif
  assign repair_ready = EXEC_REPAIR && ((wst == W_IDLE)
`ifdef VEN_UOP_CROSSLINE
                                        || cross_seek_yield
`endif
                                       )
                      && !pd_start_live && !pd_pend_live && !d16_flush
                      && store_pdv[{repair_set,repair_way}]
                      && (({1'b0,repair_off} < repair_floor[{repair_set,repair_way}])
`ifdef VEN_UOP_CROSSLINE
                          || (repair_next_valid && repair_off > 5'd25)
`endif
                         )
                      && !(inv_en && inv_set == repair_set && inv_way == repair_way)
                      && !(inv2_en && inv2_set == repair_set && inv2_way == repair_way);
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
  // Classify the condition that ended the currently buffered walk. This is
  // sampled only when W_WRITE actually publishes a valid map; it has no role
  // in arbitration or in the synthesized cache.
  logic [2:0] walk_end_reason;
  always_comb begin
    if (wslot >= SLOT_LIMIT)             walk_end_reason = UC_END_SLOT;
    else if (woff >= 6'(IC_LINE))        walk_end_reason = UC_END_LINE;
    else if (wsteps > LAST_FG_STEP)      walk_end_reason = UC_END_STEP;
    else if (scan_known)                 walk_end_reason = UC_END_TAIL;
    else                                 walk_end_reason = UC_END_UNKNOWN;
  end
`endif
`endif

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
      wext_armed <= 1'b0;
      wext_dirty <= 1'b0;
      wrepair <= 1'b0;
      wanchor <= 5'd0;
`ifdef VEN_UOP_CROSSLINE
      cross_valid_q <= 1'b0; cross_uop_q <= '0; cross_mode_q <= 1'b0;
`ifdef VEN_UOP_REPAIR_FAIR
      cross_yield_recent_q <= 1'b0;
`endif
`ifdef VEN_UOP_CROSS2
`ifdef VEN_UOP_CROSS_INDEX
      cross_index_valid <= '0;
`else
      cross_victim_valid <= 1'b0; cross_victim_uop <= '0;
      cross_victim_mode <= 1'b0; cross_victim_way <= 1'b0; cross_victim_next_way <= 1'b0;
      cross_victim_set <= '0; cross_victim_next_set <= '0; cross_victim_off <= '0;
`endif
`endif
      cross_set_q <= '0; cross_next_set_q <= '0;
      cross_way_q <= 1'b0; cross_next_way_q <= 1'b0; cross_off_q <= '0;
      wnext_valid <= 1'b0; wnext_set <= '0; wnext_way <= 1'b0;
`endif
`ifndef SYNTHESIS
      uop_skid_drop <= 0;
`endif
      for (int i=0;i<IC_SETS*2;i++) begin
        store_pdv[i] <= 1'b0;
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
        store_end_reason[i] <= UC_END_NONE;
        store_end_bytes[i] <= 48'd0;
`endif
`endif
      end
    end else begin
      d16_q <= cur_def16;
`ifdef VEN_UOP_CROSSLINE
`ifdef VEN_UOP_REPAIR_FAIR
      // Keep the credit across the intervening local repair (and across a
      // foreground fill). Consume it only when a late seek reaches its anchor
      // or is cancelled by the normal coherence/mode fences.
      if (wrepair && wst==W_SEEK && wanchor > 5'd25 &&
          (woff >= {1'b0,wanchor} || wpz || d16_flush || wnext_kill ||
           (inv_en && inv_set==wset && inv_way==wway) ||
           (inv2_en && inv2_set==wset && inv2_way==wway)))
        cross_yield_recent_q <= 1'b0;
      if (cross_seek_yield && wanchor > 5'd25)
        cross_yield_recent_q <= 1'b1;
`endif
      if (cross_kill) cross_valid_q <= 1'b0;
`ifdef VEN_UOP_CROSS2
`ifdef VEN_UOP_CROSS_INDEX
      for (int ci=0; ci<32; ci++) begin
        if (d16_flush ||
            (inv_en && ((inv_set==cross_index_meta[ci].set_id && inv_way==cross_index_meta[ci].way) ||
                        (inv_set==cross_index_meta[ci].next_set && inv_way==cross_index_meta[ci].next_way))) ||
            (inv2_en && ((inv2_set==cross_index_meta[ci].set_id && inv2_way==cross_index_meta[ci].way) ||
                         (inv2_set==cross_index_meta[ci].next_set && inv2_way==cross_index_meta[ci].next_way))))
          cross_index_valid[ci] <= 1'b0;
      end
`else
      if (cross_victim_kill) cross_victim_valid <= 1'b0;
`endif
`endif
      if (wrepair && wnext_kill) wpz <= 1'b1;
`endif
      // H-04: global predecode flush on a default-size change (takes priority over
      // the per-(set,way) invalidate below and over this fill's own validation).
      if (d16_flush)
        for (int i=0;i<IC_SETS*2;i++) begin
          store_pdv[i] <= 1'b0;
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
          store_end_reason[i] <= UC_END_NONE;
          store_end_bytes[i] <= 48'd0;
`endif
`endif
        end
      // invalidate (refill/SMC): clear predecoded-valid for the (set,way).
      if (inv_en) begin
        store_pdv[{inv_set,inv_way}] <= 1'b0;
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
        store_end_reason[{inv_set,inv_way}] <= UC_END_NONE;
        store_end_bytes[{inv_set,inv_way}] <= 48'd0;
`endif
`endif
      end
      if (inv2_en) begin
        store_pdv[{inv2_set,inv2_way}] <= 1'b0;   // R2-H09
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
        store_end_reason[{inv2_set,inv2_way}] <= UC_END_NONE;
        store_end_bytes[{inv2_set,inv2_way}] <= 48'd0;
`endif
`endif
      end
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
      // floor. Hold it in the existing one-deep skid. The terminal direct handoff
      // below makes the 12-action foreground service interval exactly 13 clocks,
      // matching the legal direct/COMB fill cadence; the skid only absorbs a
      // same-edge P/N collision, not a sustained rate mismatch. If a future
      // producer becomes faster than that contract, the simulation counter below
      // makes the resulting loss explicit instead of silently losing predecode.
      // W_WRITE/W_EXT have an atomic terminal handoff below: accepting a start
      // here as well would both launch it and leave a duplicate pending copy.
      // W_WALK still uses the one-deep skid exactly as before.
      if (pd_start_live && !wrepair && (wst != W_IDLE) && (wst != W_WRITE) && (wst != W_EXT)) begin
`ifndef SYNTHESIS
        if (pd_pend && !pd_pend_kill) begin
          uop_skid_drop <= uop_skid_drop + 1;
          $display("[UOPC] WARNING: second pd_start while one is pending (new set %0d way %0d dropped) -- REVIEW2 H-14 skid is 1-deep",
                   pd_set, pd_way);
        end
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

      // Repair is disposable, unlike a foreground fill. Directly launch the
      // oldest refill without spending a seek/walk/write clock or duplicating
      // the new start in the skid. This preserves the original refill cadence.
      if (EXEC_REPAIR && wrepair && (pd_pend_live || pd_start_live)) begin
        residual <= pd_pend_live ? pd_pend_line : pd_line;
        woff <= 6'd0; wslot <= 4'd0; wsteps <= 6'd0;
        wset <= pd_pend_live ? pd_pend_set : pd_set;
        wway <= pd_pend_live ? pd_pend_way : pd_way;
        wflags <= pd_pend_live ? pd_pend_flags : pd_flags;
        wcyc <= pd_pend_live ? pd_pend_cyc : pd_cycle_mode;
        wd16 <= pd_pend_live ? pd_pend_d16 : pd_def16;
        wbuf_base <= '0; wbuf_tail <= '0; wbuf_bmap <= '0;
        wpz <= 1'b0; wext_armed <= 1'b0; wext_dirty <= 1'b0;
        wrepair <= 1'b0; wst <= W_WALK;
        if (pd_pend_live && pd_start_live) begin
          pd_pend <= 1'b1;
          pd_pend_set <= pd_set; pd_pend_way <= pd_way;
          pd_pend_line <= pd_line; pd_pend_flags <= pd_flags;
          pd_pend_cyc <= pd_cycle_mode; pd_pend_d16 <= pd_def16;
        end else pd_pend <= 1'b0;
      end
`ifdef VEN_UOP_CROSSLINE
      else if (cross_seek_yield) begin
        // Same capture/ownership contract as W_IDLE. Discard the old optional
        // seek before it can publish; do not queue stale caller-owned bytes.
        residual <= {repair_next_valid ? repair_next_bytes : 48'd0, repair_line};
        wnext_valid <= repair_next_valid;
        wnext_set <= repair_next_set; wnext_way <= repair_next_way;
        if ((inv_en && inv_set==repair_next_set && inv_way==repair_next_way) ||
            (inv2_en && inv2_set==repair_next_set && inv2_way==repair_next_way))
          wnext_valid <= 1'b0;
        woff <= 6'd0; wslot <= '0; wsteps <= 6'd0; wanchor <= repair_off;
        wset <= repair_set; wway <= repair_way;
        wflags <= repair_flags; wcyc <= 1'b1; wd16 <= cur_def16;
        wbuf_base <= '0; wbuf_tail <= '0; wbuf_bmap <= '0;
        wpz <= 1'b0; wext_armed <= 1'b0; wext_dirty <= 1'b0;
        wrepair <= 1'b1; wst <= W_SEEK;
      end
`endif
      else unique case (wst)
        W_IDLE: begin
          wrepair <= 1'b0;
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
            wsteps     <= 6'd0;
            wext_armed <= 1'b0;
            wext_dirty <= 1'b0;
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
          end else if (repair_start && repair_ready) begin
`ifdef VEN_UOP_CROSSLINE
            residual <= {repair_next_valid ? repair_next_bytes : 48'd0, repair_line};
            wnext_valid <= repair_next_valid;
            wnext_set <= repair_next_set; wnext_way <= repair_next_way;
            // A suffix invalidation on the acceptance edge cancels its use.
            if ((inv_en && inv_set==repair_next_set && inv_way==repair_next_way) ||
                (inv2_en && inv2_set==repair_next_set && inv2_way==repair_next_way))
              wnext_valid <= 1'b0;
`else
            residual <= repair_line;
`endif
            woff <= 6'd0; wslot <= 4'd0; wsteps <= 6'd0;
            wanchor <= repair_off;
            wset <= repair_set; wway <= repair_way;
            wflags <= repair_flags; wcyc <= 1'b1; wd16 <= cur_def16;
            wbuf_base <= '0; wbuf_tail <= '0; wbuf_bmap <= '0;
            wpz <= 1'b0; wext_armed <= 1'b0; wext_dirty <= 1'b0;
            wrepair <= 1'b1; wst <= W_SEEK;
          end
        end
        W_SEEK: begin
          // Fixed byte shift, not a new 32:1 alignment mux. Only optional work
          // pays this latency. A killed line can never be resurrected by repair.
          if (wpz || d16_flush
`ifdef VEN_UOP_CROSSLINE
              || wnext_kill
`endif
              || (inv_en && inv_set == wset && inv_way == wway)
              || (inv2_en && inv2_set == wset && inv2_way == wway)) begin
            wst <= W_IDLE;
          end else if (woff < {1'b0, wanchor}) begin
            residual <= residual >> 8;
            woff <= woff + 6'd1;
`ifdef VEN_UOP_CROSSLINE
          end else if (wnext_valid && pd_exec && pd_len != 0 && pd_len <= 7 &&
                       woff + {2'd0,pd_len} > 6'(IC_LINE) &&
                       woff + {2'd0,pd_len} <= 6'(IC_LINE+6)) begin
`ifdef VEN_UOP_CROSS2
            // Preserve the displaced live entry, but never resurrect it if
            // either of its source lines is invalidated on this same edge.
            // Republishing the same identity must not evict a distinct victim.
            if (cross_valid_q && !cross_kill &&
                !(cross_set_q==wset && cross_way_q==wway && cross_off_q==wanchor &&
                  cross_next_set_q==wnext_set && cross_next_way_q==wnext_way &&
                  cross_mode_q==wd16)) begin
`ifdef VEN_UOP_CROSS_INDEX
              // The displaced source is independently checked against BOTH
              // current invalidation ports above; an old bucket's kill must
              // not cancel an unrelated new occupant written on this edge.
              cross_index_valid[cross_write_index] <= 1'b1;
              cross_index_data[cross_write_index] <= cross_uop_q;
              cross_index_meta[cross_write_index] <= '{mode16:cross_mode_q,
                  way:cross_way_q, next_way:cross_next_way_q,
                  set_id:cross_set_q, next_set:cross_next_set_q, off:cross_off_q};
`else
              cross_victim_valid <= 1'b1; cross_victim_uop <= cross_uop_q;
              cross_victim_set <= cross_set_q; cross_victim_way <= cross_way_q;
              cross_victim_next_set <= cross_next_set_q;
              cross_victim_next_way <= cross_next_way_q;
              cross_victim_off <= cross_off_q; cross_victim_mode <= cross_mode_q;
`endif
            end
`endif
            cross_uop_q <= pd_uop; cross_valid_q <= 1'b1;
            cross_set_q <= wset; cross_way_q <= wway;
            cross_next_set_q <= wnext_set; cross_next_way_q <= wnext_way;
            cross_off_q <= wanchor; cross_mode_q <= wd16;
            wst <= W_IDLE;
`endif
          end else if (pd_exec && pd_map_fits
`ifdef VEN_UOP_CROSSLINE
                       && {1'b0,wanchor} < repair_floor[{wset,wway}]
`endif
                      ) begin
            // Do not evict a useful map merely because a slow/unsupported
            // instruction missed it. The requested boundary must be mappable.
            wst <= W_EXT;
          end else begin
            wst <= W_IDLE;
          end
        end
        W_WALK: begin
          if (pd_exec) begin
            // Record only a genuine executable fpd_t. The base bank is deliberately
            // fixed at eight entries, so bit 3 is both the map bank and walker bank;
            // the tail index selects its four or eight shallow entries.
            if (!wslot[3])
              wbuf_base[wslot*FPDW +: FPDW] <= pd_uop;
            else
              wbuf_tail[wslot[TAIL_IDX_W-1:0]*FPDW +: FPDW] <= pd_uop;
            // `pd_map_fits` retains the legacy full-window condition unless
            // TAIL_LOCAL is selected.  In either mode a descriptor that really
            // crosses the physical line stays invalid.
            if (pd_map_fits)
              wbuf_bmap[woff*5 +: 5] <= {1'b1, wslot[3], wslot[2:0]};
            residual <= residual >> {pd_len, 3'b000};
            woff     <= woff + {2'd0, pd_len};
            wslot    <= wslot + 4'd1;
            wsteps   <= wsteps + 6'd1;
            // A boundary at/after byte 32 belongs to the next line; capacity
            // overflow deliberately leaves the remaining starts unmapped.
            if ((woff + {2'd0, pd_len} >= 6'(IC_LINE)) || (wslot == LAST_SLOT)
                || (wsteps == LAST_FG_STEP)) begin
              // Publish the twelve-action foreground prefix on the same cycle
              // as before.  An optional background pass is legal only when
              // this exact stop was the step cap, the just-consumed operation
              // did not fill the final slot, and there is still physical line
              // data to inspect.  Nothing in this condition touches the fast
              // reader or permits a new map format.
              if (POSTPUBLISH_EXT && (wsteps == LAST_FG_STEP)
                  && (woff + {2'd0, pd_len} < 6'(IC_LINE))
                  && (wslot != LAST_SLOT))
                wext_armed <= 1'b1;
              wst <= W_WRITE;
            end
          end else if (scan_fits_line) begin
            // Known slow instruction: consume its exact bytes without allocating a
            // slot. Most forms leave their map entry completely invalid. For the
            // exact two-byte REP MOVS/STOS class, retain the length in the four
            // otherwise-unused payload bits beneath valid=0.  This is explicitly
            // NOT a uop entry: the core still dispatches it through S_FETCH and
            // the reference slow decoder, preserving every REP element boundary.
            if (scan_slow_hint)
              wbuf_bmap[woff*5 +: 5] <= {1'b0, scan_len};
            residual <= residual >> {scan_len, 3'b000};
            woff     <= woff + {2'd0, scan_len};
            wsteps   <= wsteps + 6'd1;
            if ((woff + {2'd0, scan_len} >= 6'(IC_LINE)) || (wsteps == LAST_FG_STEP)) begin
              // A skipped instruction consumes no slot, so slot 11 is still
              // usable by the continuation.  Check the post-action capacity
              // explicitly rather than conflating it with LAST_SLOT.
              if (POSTPUBLISH_EXT && (wsteps == LAST_FG_STEP)
                  && (woff + {2'd0, scan_len} < 6'(IC_LINE))
                  && (wslot < SLOT_LIMIT))
                wext_armed <= 1'b1;
              wst <= W_WRITE;
            end
          end else begin
            // Unknown/oversize/tail grammar: commit the executable prefix already
            // accumulated and stop. Never advance by decode.sv's default len=1.
            wst <= W_WRITE;
          end
        end
        W_WRITE: begin
          // A background extension is intentionally disposable.  If a refill
          // arrived on its terminal write edge, drop those optional boundaries
          // rather than add an extra queue-service cycle.  The foreground write
          // is never skipped: it is the architectural predecode publication.
          if (!(wext_dirty && (pd_pend_live || pd_start_live))) begin
            if (EXEC_REPAIR)
              repair_floor[{wset,wway}] <= wrepair ? {1'b0,wanchor} : 6'd32;
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
`ifdef VEN_UOPCACHE_CHECK
`ifndef SYNTHESIS
            if (!(wpz || d16_flush || (wd16 != cur_def16)
                || (inv_en && (inv_set==wset) && (inv_way==wway))
                || (inv2_en && (inv2_set==wset) && (inv2_way==wway)))) begin
              store_end_reason[{wset,wway}] <= walk_end_reason;
              store_end_bytes[{wset,wway}] <= residual;
            end else begin
              store_end_reason[{wset,wway}] <= UC_END_NONE;
              store_end_bytes[{wset,wway}] <= 48'd0;
            end
`endif
`endif
          end
          // The foreground prefix has now been published with its original
          // timing.  Only enter the optional continuation while no queued or
          // same-edge fill needs the one-deep skid; it is therefore never a
          // reason to hold a real fill behind an arbitrary slow-byte run.
          if (POSTPUBLISH_EXT && wext_armed && !wpz && !d16_flush
              && !(inv_en  && (inv_set  == wset) && (inv_way  == wway))
              && !(inv2_en && (inv2_set == wset) && (inv2_way == wway))
              && !pd_pend_live && !pd_start_live)
            wst <= W_EXT;
          else if (pd_pend_live || pd_start_live) begin
            // Terminal direct handoff: W_WRITE is the only unavoidable
            // publication cycle.  Starting the next transaction here removes
            // the former W_WRITE -> W_IDLE -> W_WALK bubble, so the legal
            // 13-cycle direct/comb fill producer cannot accumulate starts.
            // If both sources exist, launch the OLDER queued one and atomically
            // replace the one-deep skid with the live newcomer (FIFO order).
            residual   <= pd_pend_live ? pd_pend_line   : pd_line;
            woff       <= 6'd0;
            wslot      <= 4'd0;
            wsteps     <= 6'd0;
            wset       <= pd_pend_live ? pd_pend_set    : pd_set;
            wway       <= pd_pend_live ? pd_pend_way    : pd_way;
            wflags     <= pd_pend_live ? pd_pend_flags  : pd_flags;
            wcyc       <= pd_pend_live ? pd_pend_cyc    : pd_cycle_mode;
            wd16       <= pd_pend_live ? pd_pend_d16    : pd_def16;
            wbuf_base  <= '0;
            wbuf_tail  <= '0;
            wbuf_bmap  <= '0;
            wpz        <= 1'b0;
            wst        <= W_WALK;
            if (pd_pend_live && pd_start_live) begin
              pd_pend       <= 1'b1;
              pd_pend_set   <= pd_set;   pd_pend_way <= pd_way;
              pd_pend_line  <= pd_line;
              pd_pend_flags <= pd_flags; pd_pend_cyc <= pd_cycle_mode; pd_pend_d16 <= pd_def16;
            end else begin
              pd_pend <= 1'b0;
            end
          end else begin
            wst <= W_IDLE;
          end
          wext_armed <= 1'b0;
          wext_dirty <= 1'b0;
        end
        W_EXT: begin
          // This state is opportunistic only. A pending/new fill wins before
          // another byte is consumed, discards the optional map work, and
          // starts directly in W_WALK. This prevents W_EXT from adding even a
          // one-cycle slip to the producer/consumer service interval.
          if (pd_pend_live || pd_start_live) begin
            residual   <= pd_pend_live ? pd_pend_line   : pd_line;
            woff       <= 6'd0;
            wslot      <= 4'd0;
            wsteps     <= 6'd0;
            wset       <= pd_pend_live ? pd_pend_set    : pd_set;
            wway       <= pd_pend_live ? pd_pend_way    : pd_way;
            wflags     <= pd_pend_live ? pd_pend_flags  : pd_flags;
            wcyc       <= pd_pend_live ? pd_pend_cyc    : pd_cycle_mode;
            wd16       <= pd_pend_live ? pd_pend_d16    : pd_def16;
            wbuf_base  <= '0;
            wbuf_tail  <= '0;
            wbuf_bmap  <= '0;
            wpz        <= 1'b0;
            wext_armed <= 1'b0;
            wext_dirty <= 1'b0;
            wst        <= W_WALK;
            if (pd_pend_live && pd_start_live) begin
              pd_pend       <= 1'b1;
              pd_pend_set   <= pd_set;   pd_pend_way <= pd_way;
              pd_pend_line  <= pd_line;
              pd_pend_flags <= pd_flags; pd_pend_cyc <= pd_cycle_mode; pd_pend_d16 <= pd_def16;
            end else begin
              pd_pend <= 1'b0;
            end
          end else if (wpz || d16_flush
              || (inv_en  && (inv_set  == wset) && (inv_way  == wway))
              || (inv2_en && (inv2_set == wset) && (inv2_way == wway))) begin
            wext_dirty <= 1'b0;
            wst <= W_IDLE;
          end else if (wslot >= SLOT_LIMIT) begin
            if (wext_dirty) wst <= W_WRITE;
            else            wst <= W_IDLE;
          end else if (pd_exec && (wslot < SLOT_LIMIT)) begin
            if (!wslot[3])
              wbuf_base[wslot*FPDW +: FPDW] <= pd_uop;
            else
              wbuf_tail[wslot[TAIL_IDX_W-1:0]*FPDW +: FPDW] <= pd_uop;
            if (pd_map_fits) begin
              wbuf_bmap[woff*5 +: 5] <= {1'b1, wslot[3], wslot[2:0]};
              wext_dirty <= 1'b1;
            end
            residual <= residual >> {pd_len, 3'b000};
            woff     <= woff + {2'd0, pd_len};
            wslot    <= wslot + 4'd1;
            wsteps   <= wsteps + 6'd1;
            // A full slot bank or physical line tail is the natural end of
            // extension.  W_WRITE republishes only if at least one newly
            // visible boundary exists; otherwise the private data is inert.
            if ((woff + {2'd0, pd_len} >= 6'(IC_LINE)) || (wslot == LAST_SLOT))
              wst <= W_WRITE;
          end else if (scan_fits_line) begin
            // Preserve the same invalid-map short descriptor in the optional
            // background continuation.  W_EXT is normally off, but a descriptor
            // must not depend on whether the foreground walk happened to hit its
            // twelve-action budget.
            if (scan_slow_hint) begin
              wbuf_bmap[woff*5 +: 5] <= {1'b0, scan_len};
              // Unlike a foreground descriptor, this update is not published
              // unless W_EXT marks the working buffer dirty.  Include the
              // current-cycle value in the terminal decision below too: this is
              // a nonblocking assignment, so `wext_dirty` alone is still old.
              wext_dirty <= 1'b1;
            end
            residual <= residual >> {scan_len, 3'b000};
            woff     <= woff + {2'd0, scan_len};
            wsteps   <= wsteps + 6'd1;
            if (woff + {2'd0, scan_len} >= 6'(IC_LINE)) begin
              if (wext_dirty || scan_slow_hint) wst <= W_WRITE;
              else            wst <= W_IDLE;
            end
          end else begin
            // Unknown grammar and known cross-line forms remain fail-closed.
            // They do not manufacture a later executable boundary.
            if (wext_dirty) wst <= W_WRITE;
            else            wst <= W_IDLE;
          end
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

endmodule : uopcache
