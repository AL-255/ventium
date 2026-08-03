`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_l1d.sv — L1 unified data array + line-fill engine (P1-1 step 1).
//
// The DATA half the cycle model never needed (dcache_timing.sv is timing-only —
// load data came from the BFM via mem_rdata). On the real FPGA there is no BFM:
// hit data must come from a PL-side array, and a miss must pull the 32-byte line
// from the backing memory (the BFM in sim now; the AXI4 master → PS-DDR later).
// This module is that array + the miss line-fill FSM, sitting BETWEEN the core's
// mem_* port (the same-cycle-ack contract) and a backing mem_* port. See
// fpga/L1_AXI_DESIGN.md §2/§3.
//
// Geometry: 8 KB, 2-way, 32-byte line, 128 sets — IDENTICAL to icache + the oracle
// p5trace L1, so cache behaviour stays consistent. Data = packed 256-bit lines in
// distributed RAM (the icache pattern, P0-3: shallow-and-wide → LUTRAM, async read
// so a HIT returns combinationally for the same-cycle ack). tag/val/lru mirror
// dcache_timing's 2-way-LRU.
//
// Contract (fpga/L1_AXI_DESIGN.md §1):
//   * READ HIT  → c_rdata = the addressed word, c_ack=1, SAME CLOCK (no backing).
//   * READ MISS → c_ack=0 (core stalls), the fill FSM bursts the 32-byte line
//     (8 words) from the backing, allocates the not-MRU victim, then the retry hits.
//   * WRITE     → write-THROUGH: update the array on a hit (byte strobes) AND
//     forward to the backing; c_ack follows the backing ack. (No write-allocate —
//     a write miss does not pull the line; write-back/MESI is a later optimization.)
// At most one core transaction in flight (the core's mem port is single-beat).
//
// NOT YET WIRED into the core: bus_mode=2 + the fast-path load's miss-stall gate are
// the next step. Standalone-synthesizable + unit-checkable as-is.

module ven_l1d #(
    parameter int L1_SETS = 128,
    parameter int L1_LINE = 32           // bytes/line (256-bit packed line)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- #35 external invalidation: clear ALL valid bits (a conservative flush)
    // for the cosim — the int-0x80 proxy / syscall emulator writes the backing
    // MemModel DIRECTLY (bypassing the L1), so without this a re-read after a
    // syscall-filled buffer (Quake) would hit a STALE cached line. Pulse flush_all
    // after each such write; the next reads miss and refill from the backing. On
    // real HW the HPC0 CCI snoop covers AXI writes; tied 0 in modes 0/1.
    input  logic        flush_all,

    // ---- golden / "L1-useless" mode (diagnostic): after EVERY completed core
    // transaction, drop all cached state (valid bits + the registered read window)
    // so the NEXT access fully re-fills from the backing and re-captures fresh — no
    // L1 state survives a transaction. Tanks performance (every access misses), but
    // produces a result uncontaminated by L1 line-staleness / read-window bugs: if a
    // fetch corruption PERSISTS with golden=1, the bug is NOT in L1's carried state
    // (it is downstream — the core fetch buffer); if it VANISHES, L1 state was the
    // cause. Runtime bit (MODE.GOLDEN_L1); tied 0 = normal cached operation.
    input  logic        golden,

    // ---- KEN# (cacheability) — the northbridge ven_cachemap decision for THIS
    // access (docs/northbridge-system-spec.md §3). 1 = normal cached operation
    // (the Phase A default at every instantiation). 0 = NON-ALLOCATING BYPASS: the
    // line is never allocated/touched in the array; a read fetches the addressed
    // line into a private buffer and serves the word from there (no pollution), a
    // write goes straight write-through. An uncacheable address has a STABLE PAM
    // attribute, so it is never resident — hence no force-miss of a stale hit is
    // needed (the bypass path simply never consults/installs the array). Tied 1
    // until the cachemap is wired (Phase C), so the default build is byte-identical.
    input  logic        cacheable,

    // ---- per-line snoop INVALIDATE (the EADS#/inquire analogue) — the northbridge
    // pulses this for one clock when a NON-CPU master (DMA / PCI) writes a line that
    // may be cached here, so the next CPU read of it misses and refills the new data
    // (the L1 is write-through, so it is never dirtier than L2 — invalidate suffices,
    // no write-back). Clears the matching {set,way} valid bit if resident; harmless
    // if absent. Tied 0 until DMA is a coherent requester (Phase D) → byte-identical.
    input  logic        snoop_inv_valid,
    input  logic [31:0] snoop_inv_addr,

    // ---- core side (the same-cycle-ack contract; mirrors core mem_*) ----------
    input  logic        c_req,
    input  logic        c_we,
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wstrb,
    output logic [31:0] c_rdata,
    output logic        c_ack,
    // VEN DIAG (load-serve forensics): expose the read-serve hit state so the dbg ring can show WHY a
    // load got its data. {1'b0,st[1:0],flush_all,rd_match,hit_way,hit1,hit0} sampled at the current request.
    output logic [7:0]  dbg_serve,

    // ---- backing side (BFM now; AXI4 master → PS-DDR later) -------------------
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    input  logic [31:0] m_rdata,
    input  logic        m_ack
);

  localparam int LW = L1_LINE*8;         // 256 line bits
  localparam int WORDS = L1_LINE/4;      // 8 words/line
  // REVIEW2 M-04: DERIVED geometry. The set-index / tag split was hard-coded as
  // [11:5] and [31:12], so overriding L1_SETS indexed dc_tag/dc_val past their end AND
  // split the address at the wrong bit -- silently wrong data, not a compile error.
  // These make the split follow the parameter instead.
  localparam int OFFW  = $clog2(L1_LINE);              // 5 for 32-byte lines
  localparam int IDXW  = $clog2(L1_SETS);              // 7 for 128 sets
  localparam int TAGW  = 32 - OFFW - IDXW;             // 20 for the 128x32 geometry

  // ---- arrays ----------------------------------------------------------------
  // Data: packed 256-bit lines, flat {set,way} index → distributed RAM (async
  // read for the same-cycle hit). tag/val/lru: 2-way LRU (== dcache_timing).
  (* ram_style = "distributed" *)
  logic [LW-1:0] dc_line [L1_SETS*2];
  logic [TAGW-1:0] dc_tag [L1_SETS][2];  // addr[31 -: TAGW]
  logic          dc_val  [L1_SETS][2];
  logic          dc_lru  [L1_SETS];      // way most-recently-used

  // REVIEW2 M-04: this module ADVERTISED L1_SETS/L1_LINE but hard-coded seven set-index
  // bits [11:5], a 20-bit tag [31:12] and offset bit 5, so overriding L1_SETS indexed
  // dc_tag/dc_val past their end AND split the address at the wrong bit -- silently
  // wrong data, not a compile error.
  //
  // FIXED for L1_SETS: the split is now derived (OFFW/IDXW/TAGW above) and every set/
  // tag reference follows the parameter, so 64/128/256 sets all index and tag
  // correctly. That is the half the review's hazard was about ("overriding the
  // parameter to 64 can index beyond the array and uses the wrong tag split").
  //
  // STILL PINNED for L1_LINE: the line geometry is woven through the byte-select
  // datapath, not just the address split. Guarded below.
  initial begin
    // L1_SETS is now HONOURED: the set/tag split is derived above, so 64/128/256 all
    // index correctly and tag the right bits. It must still be a power of two, since
    // $clog2 is what makes the split exact.
    if ((L1_SETS & (L1_SETS-1)) != 0 || L1_SETS < 2)
      $fatal(1, "ven_l1d: L1_SETS=%0d must be a power of two >= 2 (the set/tag split is derived with $clog2).", L1_SETS);
    // L1_LINE is still PINNED. Unlike the set/tag split, the line geometry is woven
    // through the byte-select datapath -- the 32-byte read window, the bypass line
    // extract, the 8-beat fill loop and the within-line store offset all assume 5
    // offset bits. Refuse to elaborate rather than let it be found as corrupted data.
    if (L1_LINE != 32)
      $fatal(1, "ven_l1d: L1_LINE=%0d unsupported -- the byte-select datapath assumes 32-byte lines / 5 offset bits (REVIEW2 M-04, remaining half).", L1_LINE);
  end

  // ---- combinational lookup off the registered arrays (PRE-update) ----------
  logic [IDXW-1:0] set_c; logic [TAGW-1:0] tag_c;
  logic        hit0, hit1, hit; logic hit_way;
  assign set_c   = c_addr[OFFW +: IDXW];
  assign tag_c   = c_addr[OFFW+IDXW +: TAGW];
  assign hit0    = dc_val[set_c][0] && dc_tag[set_c][0]==tag_c;
  assign hit1    = dc_val[set_c][1] && dc_tag[set_c][1]==tag_c;
  assign hit     = hit0 || hit1;
  assign hit_way = hit1;                 // way 1 iff way0 misses (assumes hit)

  // ---- next-line lookup: a 4-byte access whose bytes cross the 32-byte line end
  // (c_addr[4:0] > 28) needs the NEXT line too. The core's mem port is byte-
  // addressable (the BFM reads 4 bytes at any byte addr — e.g. a slow-path S_FETCH
  // of an instruction that straddles a line boundary), so the L1 must serve such
  // reads from {next_line, line}. For a read to HIT, BOTH lines must be resident;
  // a miss fills whichever line is missing (L first, then L+1).
  logic [31:0] addr_n;
  logic [IDXW-1:0] set_n; logic [TAGW-1:0] tag_n;
  logic        hit_n0, hit_n1, hit_n, hit_way_n, xline, rd_hit;
  assign addr_n    = c_addr + 32'd32;          // the next 32-byte line
  assign set_n     = addr_n[OFFW +: IDXW];
  assign tag_n     = addr_n[OFFW+IDXW +: TAGW];
  assign hit_n0    = dc_val[set_n][0] && dc_tag[set_n][0]==tag_n;
  assign hit_n1    = dc_val[set_n][1] && dc_tag[set_n][1]==tag_n;
  assign hit_n     = hit_n0 || hit_n1;
  assign hit_way_n = hit_n1;
  assign xline     = (c_addr[4:0] > 5'd28);    // 4-byte access spills into the next line
  // ---- REVIEW1_Aug2 H-07: a non-cacheable READ must not be served from the array ---
  // NOT FIXED. The analysis below is correct and the fix attempt is recorded because it
  // failed in an instructive way.
  // Under VEN_L1_HONOR_CD the bypass-read FSM is disabled (it deadlocks in the
  // full-core+bridge context -- a measured claim recorded at the L1_IDLE arm), and the
  // comment there argues the allocating path is "correct (returns the fresh line)".
  // That is true of a read MISS and false of a read HIT: rd_hit is computed from the
  // array regardless of `cacheable`, so a still-resident line served CACHED data after
  // CD was set -- stale pre-CD RAM, and for a cache-mapped MMIO region a suppressed
  // read side effect. That is the half of H-07 that is a correctness bug rather than a
  // performance one.
  //
  // Suppressing the HIT sends the access down the ordinary allocating fill, which
  // fetches the line from memory and therefore returns FRESH data. It does not fix the
  // allocation itself -- MMIO read side effects are still duplicated by the burst, and
  // that needs the bypass FSM the review asks for -- but it removes the stale-data
  // path without touching the FSM that is documented to hang.
  //
  // Only under VEN_L1_HONOR_CD: with the bypass enabled (the default build) a
  // non-cacheable read already takes L1_BYP and never consults rd_hit for service.
  // MEASURED, not reasoned: gating this on `cacheable` under VEN_L1_HONOR_CD -- the
  // obvious fix, and the one that removes the stale-data path -- DEADLOCKS. The access
  // is routed to the fill, but the post-fill serve consults rd_hit too, and rd_hit is
  // still suppressed because `cacheable` is still 0, so the read never acks:
  //     [9c] ... FAIL nc read of resident line is FRESH: got 00000000 exp deadbeef
  //          FAIL read 0000509c: no ack
  // That is the same shape the L1_IDLE comment records for the bypass FSM, and it is
  // why H-07 needs an actual SERVE path that does not depend on a cacheable hit --
  // exactly the "non-deadlocking read bypass" the review asks for. Left as the plain
  // array hit; the [9c] case below documents the property a correct fix must satisfy.
  assign rd_hit    = hit && (!xline || hit_n); // a READ hits iff both needed lines resident

  // addressed line read (the hit way) + the BYTE offset within it. The core's mem
  // port is BYTE-addressable (the sim BFM reads the 4 bytes starting at the exact
  // byte address — e.g. an unaligned slow-path S_FETCH at the instruction address),
  // so the L1 must extract the 4 bytes at c_addr[4:0], NOT the aligned word at
  // c_addr[4:2]. (Aligned accesses — every L1D/L1AXI gate read + the line fill — have
  // c_addr[1:0]=0, so {boff,3'b0} == {word_c,5'b0} and they are unchanged.) A read
  // whose 4 bytes cross the 32-byte line end (c_addr[4:0] > 28) is NOT handled here
  // (it would need the next line too) — see the cross-line note in P1-1.
  logic [LW-1:0]   rd_line, rd_line_next;
  logic [2*LW-1:0] rd_window;                          // {L+1, L} cross-line read window
  logic [4:0]      boff;
  assign rd_line      = dc_line[{set_c, hit_way}];
  assign rd_line_next = dc_line[{set_n, hit_way_n}];   // the L+1 line (for a cross-line read)
  assign rd_window    = {rd_line_next, rd_line};       // named temp: xsim can't index a concat
  assign boff         = c_addr[4:0];

  // ---- PIPELINED READ (timing-closure): register the high-fanout async line read.
  // The async read of dc_line (256-bit-wide distributed RAM, 256 entries) has huge
  // fanout (>1100) and ~49 logic levels through the {set,way} mux — it does not close
  // 40 MHz timing and GLITCHES on silicon (the free-run Quake derail). Registering
  // rd_window into rd_window_q breaks that path (now: eip_reg -> async read -> a FF,
  // then FF -> output mux as two short paths). The core polls mem_ack, so a 1-cycle
  // read latency is fine.
  //
  // CRITICAL: the ack must be GUARDED by an address match. The core does not cleanly
  // "hold addr, wait for ack, then advance" — it can present a NEW c_addr while a prior
  // read's ack (rd_armed) is still asserted (different cache SET, even). A bare
  // `c_ack = rd_armed` then serves rd_window_q (captured for the OLD addr) to the NEW
  // addr -> stale data -> derail. rd_addr_q records which address the window was
  // captured for; we only ack (and suppress re-capture) when it matches the live
  // request, so stale data can NEVER be acked for a mismatched address.
  logic            rd_armed;
  logic [2*LW-1:0] rd_window_q;
  logic [31:0]     rd_addr_q;       // address rd_window_q was captured for
  logic            rd_match;        // captured window is valid for the CURRENT request
  logic            do_rd_cap;
  assign rd_match  = rd_armed && (rd_addr_q == c_addr);
  // REVIEW Aug-1 H-05: do_rd_cap is derived from the COMBINATIONAL hit, which reads
  // pre-edge tag/valid. If a snoop for that same line lands on the same clock, the
  // array's valid bit is cleared at the edge but the OLD window has already been
  // captured and rd_armed set -- and the next response is served through rd_match,
  // which compares only the ADDRESS and never re-checks current tag/valid. The core
  // then gets acked with pre-DMA data (repro: HIT_SNOOP_RACE stale=11110000
  // backing=22220000). Suppress the capture whenever a snoop is in flight.
  //
  // The window is 2*LW wide (it spans the addressed line AND the next one, for
  // cross-line reads), so a precise per-line comparison would have to cover both.
  // Snoops are rare (DMA bursts), so kill ANY capture during one: cheap, and there
  // is no address arithmetic left to get wrong.
  // REVIEW2 H-18: CR0.CD / KEN# were honoured for WRITES but not for READS. rd_hit is
  // computed from the array regardless of `cacheable`, so a still-resident line served
  // a CACHED HIT even when the access must bypass -- returning pre-CD data, and with
  // the optional cache map, duplicating or suppressing MMIO side effects.
  //
  // bypass_rd_en is the single predicate for "a non-cacheable read takes the L1_BYP
  // path". It gates BOTH this capture and the FSM branch that starts the bypass fill,
  // so the two cannot disagree -- if the capture were gated while the branch was not
  // (or vice versa) a non-cacheable read would either serve stale data or never be
  // served at all. Under VEN_L1_HONOR_CD the bypass FSM is deliberately disabled (see
  // the L1_IDLE arm), so there the capture must stay ungated or the read deadlocks.
// REVIEW1_Aug2 H-07: this was 0 under VEN_L1_HONOR_CD, so a non-cacheable read was
// served from the ARRAY -- returning pre-CD data, and for MMIO duplicating or
// suppressing read side effects. It is now 1 in both builds; see the L1_IDLE arm and
// the c_ack gating below for the two changes that make that non-deadlocking.
  localparam bit BYPASS_RD_EN = 1'b1;
  assign do_rd_cap = c_req && !c_we && rd_hit && (st==L1_IDLE) && !rd_match
                     && !snoop_inv_valid
                     && !(BYPASS_RD_EN && !cacheable);   // H-18: CD/KEN# read bypass
  assign dbg_serve = {1'b0, st[1:0], flush_all, rd_match, hit_way, hit1, hit0};  // mini-ILA: L1D FSM + serve state

  // H-06/H-07: does an in-flight snoop hit the line currently being allocated?
  // fset/ftag are REGISTERED at fill start, so this is a clean compare that does not
  // depend on the (pre-edge) array contents. Bypass fills allocate nothing, so they
  // cannot go stale in the array and are excluded.
  assign snoop_hits_fill = snoop_inv_valid && !bypass_q &&
                           (snoop_inv_addr[OFFW +: IDXW]      == fset) &&
                           (snoop_inv_addr[OFFW+IDXW +: TAGW] == ftag);

  // ---- fill FSM --------------------------------------------------------------
  // L1_BYP: a non-cacheable read has finished its line fetch into bp_line; serve the
  // addressed word for one clock (c_ack below), allocating NOTHING, then back to IDLE.
  typedef enum logic [1:0] { L1_IDLE, L1_FILL, L1_DONE, L1_BYP } l1_state_e;
  l1_state_e   st;
  logic [2:0]  fw;                       // fill word counter 0..7
  logic [IDXW-1:0] fset; logic fway; logic [TAGW-1:0] ftag;
  // REVIEW Aug-1 H-06/H-07: a line fill is an 8-beat TRANSACTION, but its tag/valid
  // are installed only on the LAST beat. An invalidation arriving during beats 0..6
  // therefore has nothing to match and is silently lost; the last beat then validates
  // a line whose backing store has already changed underneath it (repros:
  // FLUSH_DURING_FILL and SNOOP_DURING_FILL, both stale=11110000 backing=22220000).
  // A same-cycle LAST-beat snoop is lost too: the snoop block's `dc_val[set][way] &&
  // dc_tag[set][way]==tag` guard reads the PRE-EDGE array (nonblocking), which for the
  // line being allocated is still valid=0 -- so the "LAST in the FF so an invalidation
  // wins over a same-cycle allocate" comment does not actually hold for a fill.
  //
  // Make it transactional: latch a poison bit on any flush, or on a snoop matching the
  // line being filled, at any point between start and finish. A poisoned fill still
  // drains its beats on the bus (the AXI transaction must complete) but does NOT
  // validate, so the core misses and refills from the now-current backing.
  logic fill_poison;
  logic snoop_hits_fill;
  logic [31:0] fbase;                    // line base address of the miss
  // non-cacheable bypass: capture the fetched line into a PRIVATE buffer (not the
  // array) and remember we are bypassing, so the fill commits nothing.
  logic [LW-1:0] bp_line;
  // REVIEW2 H-19: a non-cacheable read at byte offsets 29..31 needs up to 4 bytes from
  // the FOLLOWING line. The bypass buffer held ONE line and the top 32 bits of the
  // window were hard-zeroed, so those reads returned CORRUPT DATA -- in precisely the
  // path intended for MMIO / CR0.CD bypass, where a wrong value is a wrong device
  // access. Fetch the next line's first word in a 9th beat instead of inventing zeros.
  logic [31:0]   bp_hi;      // next line's word 0 (only meaningful when byp_need_hi)
  logic          byp_need_hi;  // this bypass access crosses the line end
  logic          byp_hi_beat;  // the 9th beat is in flight
  logic          bypass_q;

  // backing-side drive: during a FILL, burst-read the 8 line words; on a
  // write-through (IDLE), pass the core write straight to the backing.
  always_comb begin
    m_req=1'b0; m_we=1'b0; m_addr=32'd0; m_wdata=32'd0; m_wstrb=4'd0;
    if (st==L1_FILL) begin
      m_req  = 1'b1; m_we = 1'b0;
      // H-19: during the extra beat, address the NEXT line's word 0.
      m_addr = byp_hi_beat ? ({fbase[31:5], 5'd0} + 32'd32)
                           : ({fbase[31:5], 5'd0} + {27'd0, fw, 2'b00});
    end else if (st==L1_IDLE && c_req && c_we) begin
      // write-through: forward EVERY core write to the backing verbatim (the
      // write-allocate is disabled above). This now includes the within-line cacheable
      // write MISS (!hit && !xline && cacheable) — with no allocate, its store MUST be
      // forwarded here or it would never reach backing and c_ack would never fire (the
      // core would stall forever). HIT updates the cached copy (FF below); MISS caches
      // nothing; xline invalidates + forwards; non-cacheable forwards straight through.
      m_req=1'b1; m_we=1'b1; m_addr=c_addr; m_wdata=c_wdata; m_wstrb=c_wstrb;
    end
  end

  // REVIEW_Jul29 H-13: the L1_BYP (non-cacheable) serve indexed the 256-bit bp_line
  // with {c_addr[4:0],3'b000} +: 32. At byte offsets 29..31 that selects bits
  // 232..279 — PAST THE END of the vector. An out-of-range part-select is not an
  // error, it silently yields X / zero / TOOL-DEPENDENT bits, so Verilator and
  // Vivado could disagree on the same unaligned uncacheable/MMIO dword.
  // Two things here:
  //   1) index a zero-extended copy so the select is always IN RANGE and the
  //      behaviour is at least DETERMINISTIC and identical across tools;
  //   2) flag the crossing loudly in simulation, because deterministic-but-wrong
  //      would otherwise MASK the defect.
  // The real fix is to split the access by its actual byte span and merge the two
  // responses (the cacheable path already builds a {next,current} window for this);
  // that needs bypass-FSM work and is tracked in task #40.
  // ===========================================================================
  // REVIEW2_aug2 H-11 -- NON-CACHEABLE READS ARE AMPLIFIED INTO FULL LINE BURSTS.
  // NOT FIXED. Recorded here, at the code it indicts, rather than in a status note.
  //
  // A non-cacheable read reuses the FILL burst (L1_IDLE -> L1_FILL with bypass_q),
  // so ONE architectural read becomes a 32-byte, eight-beat request -- and
  // ven_axi_master's priming normally issues it twice. For MMIO that is not a
  // performance question but a CORRECTNESS one: read-to-clear registers are cleared
  // eight-plus times, FIFOs pop repeatedly, and adjacent addresses with unrelated
  // side effects are touched.
  //
  // EXPOSURE: the bypass branch is taken only when `cacheable` is 0, and
  // ventium_l1_axi ties l1d_cacheable to 1'b1 except under VEN_L1_HONOR_CD (line
  // ~604, `~cr0_cd`). So this is live in the HONOR_CD build -- the one H-07 just
  // repaired -- and dormant in the default one. It is not "unreachable"; it is
  // reachable exactly where the CD feature is switched on.
  //
  // WHAT THE FIX REQUIRES: a width-accurate single-access path -- issue ONE beat at
  // the exact byte address and width, and serve from that beat rather than from a
  // 256-bit line image. That is a COORDINATED change to both halves: the fill driver
  // (stop after one beat when bypass_q) and the L1_BYP serve (bp_line_x is indexed by
  // c_addr[4:0] on the assumption the whole line was fetched, so a single-beat fill
  // would leave it indexing bytes that were never read).
  //
  // NOT ATTEMPTED HERE, deliberately: this FSM has a recorded deadlock history
  // (L1_FILL->L1_BYP, see the rd_hit note above), the H-07 repair in it landed only
  // after a misdiagnosis was unwound, and a half-done split would produce exactly the
  // silent wrong-data class this comment exists to prevent. It wants a directed
  // read-side-effect test (a read-to-clear model in the BFM) alongside it, which does
  // not exist yet.
  // ===========================================================================
  logic [287:0] bp_line_x;
  assign bp_line_x = {bp_hi, bp_line};   // H-19: real high word, not zeros
  wire byp_cross = (st==L1_BYP) && (c_req && !c_we) && (c_addr[4:0] > 5'd28);
`ifndef SYNTHESIS
  always @(posedge clk) if (byp_cross)
    $display("[VEN-L1D] WARNING: non-cacheable read crosses the bp_line end (addr=%08h off=%0d) — split access NOT implemented (REVIEW H-13); high bytes read as 0.",
             c_addr, c_addr[4:0]);
`endif

  // core-side response: HIT (read) returns combinationally; a write acks with the
  // backing; a read miss deasserts c_ack and kicks the fill (handled in the FF).
  always_comb begin
    // 4 bytes at the addressed byte offset, from the {L+1, L} window so a read that
    // crosses the line end (boff > 28) takes its high bytes from the next line.
    // In L1_BYP (non-cacheable read) the data comes from the private bp_line buffer
    // instead — the addressed word at c_addr[4:0] (aligned; cross-line uncacheable
    // reads are not generated for MMIO and are out of scope here).
`ifdef VEN_L1D_COMB_ACK
    // COSIM-ONLY perf (NEVER synthesize — the registered rd_window_q path below exists for
    // 40 MHz fmax / anti-glitch closure; this combinational serve does not meet timing on
    // silicon). Serve the read HIT in the SAME cycle: both the data AND the byte-select come
    // from the LIVE c_addr window (rd_window / c_addr), so there is no captured-window stale
    // exposure at all — strictly VALUE-IDENTICAL to the registered serve, just one cycle
    // earlier. Saves 1 clk on every S_FETCH word + every data-load HIT (~20-30% of POST
    // cycles). rd_armed/rd_window_q/rd_addr_q still update below (harmless dead logic here).
    c_rdata = (st==L1_BYP) ? bp_line_x[{1'b0,c_addr[4:0],3'b000} +: 32]   // H-13: in-range select
                           : rd_window[{1'b0,c_addr[4:0],3'b000} +: 32];   // LIVE window, LIVE offset
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we)            c_ack = (st==L1_IDLE) ? m_ack : 1'b0;  // write-through forwards EVERY write (allocate disabled) -> ack on backing
      // REVIEW2 H-13: same gating on the combinational-ack variant.
      // REVIEW1_Aug2 H-07: the ARRAY ack term must not fire for a non-cacheable read of
      // a RESIDENT line -- that is precisely the "resident data returned after CD is
      // set" the finding describes, and it would also ack with stale data on the same
      // clock the L1_IDLE arm starts the bypass fill. Gated HERE, on the ack term,
      // rather than on rd_hit: rd_hit is also consulted by the POST-FILL serve, and
      // gating it there is what made the previous attempt deadlock.
      else                 c_ack = (rd_hit && (st==L1_IDLE) && !flush_all && !snoop_inv_valid
                                    && !(BYPASS_RD_EN && !cacheable))
                                 || (st==L1_BYP);                            // non-cacheable bypass serve
    end
`else
    // (STLD REMOVED — the store-to-load overlay POISONED PS-visible updates: an ancient CPU
    // write of BDA kbd tail=0x1E sat in the 32-entry buffer and overlaid EVERY fresh read of
    // 0x41C forever, so daemon-injected keys were invisible. The coherence problem it was
    // built for was actually the LGDT base bug. Clean registered serve restored.)
    c_rdata = (st==L1_BYP) ? bp_line_x[{1'b0,c_addr[4:0],3'b000} +: 32]   // H-13: in-range select
                           : rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we)            c_ack = (st==L1_IDLE) ? m_ack : 1'b0;  // write-through forwards EVERY write (allocate disabled) -> ack on backing
      // REVIEW1_Aug2 H-07: same array-ack suppression as the combinational variant
      // above -- see the comment there for why this is on the ack term, not rd_hit.
      // REVIEW2 H-13: suppressing the CAPTURE during a snoop was not enough. If a
      // window was armed on the PREVIOUS clock and the snoop arrives on the SERVE
      // edge, rd_match is still true (it compares only the address, never current
      // tag/valid) and the core's sequential logic samples c_ack=1 with the stale
      // rd_window_q at that very edge, while the array clears valid. Gate the
      // RESPONSE itself, not just the capture.
      else                 c_ack = (rd_match && !flush_all && !snoop_inv_valid)
                                 || (st==L1_BYP);             // non-cacheable bypass serve
    end
`endif
  end

  // golden / "L1-useless" mode: a core transaction completes (acks) this clock. We
  // drop all cached state on the NEXT edge so nothing carries into the following
  // access. c_ack is the completion edge for both reads (rd_match) and writes (m_ack).
  logic txn_done;
  // build #24: NARROW golden to the low 1 MiB (real-mode DOS memory, incl. the FreeDOS relocation
  // source). golden (flush-all + rd_window_q clear per txn) FIXED the relocation coherence bug in
  // build #23, but flushing on EVERY access (incl. Win95 protected-mode >=1MB) is ~10x slow. Gating to
  // <1MB keeps the real-mode boot coherent (correct copy) while extended-memory accesses cache at full
  // speed -> the boot can actually reach the desktop.
  assign txn_done = golden && c_req && c_ack && (c_addr[31:20] == 12'h000);

  // (STLD store-to-load forwarding REMOVED — see the serve-path note above. It was built
  // for a misdiagnosed coherence theory (the real bug was the 16-bit LGDT base) and its
  // indefinite-lifetime entries overlaid stale CPU-write data onto PS-updated lines.)

  // ---- sequential: fill sequencing + array writes ---------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=L1_IDLE; fw<=3'd0; rd_armed<=1'b0; rd_window_q<='0; rd_addr_q<=32'd0;
      bypass_q<=1'b0; bp_line<='0; fill_poison<=1'b0;
      bp_hi<=32'd0; byp_need_hi<=1'b0; byp_hi_beat<=1'b0;   // H-19
      for (int s=0;s<L1_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;
      end
    end else begin
      rd_armed <= do_rd_cap && !flush_all;
      if (do_rd_cap && !flush_all) begin
        rd_window_q <= rd_window;
        rd_addr_q   <= c_addr;        // remember which address this window serves
      end
      unique case (st)
        L1_IDLE: begin
          // REVIEW1_Aug2 H-07: this branch was `if (1'b0)` under VEN_L1_HONOR_CD, on the
          // grounds that the bypass FSM "deadlocks in the full-core+bridge context".
          // The recorded deadlock was real but was caused by a DIFFERENT change --
          // gating rd_hit itself on `cacheable`, which also suppresses the POST-FILL
          // serve, so the read never acks (see the rd_hit comment above).
          //
          // The serve path this needs already exists and does NOT consult rd_hit:
          //     c_ack   = (array hit ...) || (st==L1_BYP)
          //     c_rdata = (st==L1_BYP) ? bp_line_x[...] : rd_window[...]
          // L1_BYP serves from the PRIVATE bp_line buffer and acks on state alone. The
          // one thing missing was suppressing the ARRAY ack term for a non-cacheable
          // read of a RESIDENT line -- otherwise c_ack fired from the array with stale
          // data on the same clock this branch started the bypass fill. That gating is
          // on the c_ack term, NOT on rd_hit, which is the whole distinction.
          //
          // NOTE this branch was also dead in the non-HONOR_CD build: there
          // ventium_l1_axi ties l1d_cacheable to 1'b1, so `!cacheable` never held. The
          // FSM was unreachable in BOTH configurations, which is why the review calls
          // it untested.
          if (c_req && !c_we && !cacheable) begin
            // NON-CACHEABLE READ (KEN# negated): fetch the addressed line into the
            // private bp_line buffer (no array touch, no LRU), then serve the word in
            // L1_BYP. Reuses the FILL burst; allocates NOTHING.
            fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            fw <= 3'd0;  bypass_q <= 1'b1;  st <= L1_FILL;
            // H-19: does this access need bytes from the following line?
            byp_need_hi <= (c_addr[4:0] > 5'd28);
            byp_hi_beat <= 1'b0; bp_hi <= 32'd0;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
          end else if (c_req && !c_we && !rd_hit) begin
            // read MISS → fill the MISSING line into its not-MRU victim way. On a
            // xline-line read where L is resident but L+1 is not, fill L+1; the core
            // holds the request so the retry then fills L (if needed) -> L+1 -> hits.
            bypass_q <= 1'b0;
            if (!hit) begin
              fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            end else begin            // hit_L but xline && !hit_n -> fill the next line
              fset <= set_n; fway <= ~dc_lru[set_n]; ftag <= tag_n; fbase <= addr_n;
            end
            fw <= 3'd0;  st <= L1_FILL;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
          end else if (1'b0 && c_req && c_we && !xline && !hit && cacheable) begin
            // DISABLED (Win95 REP-MOVSB relocation fix): the write-allocate STALLS the core
            // (c_ack=0) through an 8-beat fill on every write MISS. Under real FPGA DDR latency a
            // long back-to-back REP MOVSB relocation to fresh dest lines (FreeDOS kernel -> 0x80000)
            // diverges here — the dest keeps stale data. The write ack now waits for BVALID (posted
            // writes drain), so a clean per-store write-through (the else-branch below) is globally
            // visible without the allocate's fill/retry/stall. The original __init_libc AXI_WPOST
            // read-back is covered by the BVALID wait. Keep the allocate arm text for reference:
            // WRITE-ALLOCATE: a within-line write MISS fills the addressed line into
            // the not-MRU victim FIRST; the core holds the store (c_ack=0) and the
            // post-fill retry hits -> RMW the cached copy + write-through. Without the
            // allocate the store is write-through ONLY, and a later read MISS of the
            // same line fills from not-yet-globally-visible (posted) backing -> STALE
            // data. That is the free-run __init_libc derail: `rep stos` zeroes an
            // uncached buffer then reads it back; single-step drained the posted write
            // between instructions so it only bit on silicon (AXI_WPOST sim repro).
            bypass_q <= 1'b0;
            fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            fw <= 3'd0;  st <= L1_FILL;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
          end else if (c_req && !c_we && rd_hit) begin
            // read HIT → 2-way LRU touch (both lines on a xline-line hit).
            dc_lru[set_c] <= hit_way;
            if (xline) dc_lru[set_n] <= hit_way_n;
          end else if (c_req && c_we) begin
            // WRITE (write-through). The backing received the full byte-accurate store
            // via the comb driver (ven_axi_master splits a cross-word / cross-line
            // store into per-word AXI beats); the core STALLS (c_ack=m_ack, below)
            // until that completes, so committing the array now is correct and robust
            // to multi-cycle backing latency. Keep the cached copy coherent:
            if (!xline && hit) begin
              // FIX D (UPDATE 94, cluster->sector RMW): WRITE HIT, within a single line ->
              // byte-accurate UPDATE-IN-PLACE of the hit way, keeping the line VALID+MRU, so an
              // immediately-following LOAD of the same address HITS the fresh value. This is the
              // fix for tight same-address read-modify-write loops — the FAT driver's
              // (cluster-2)*spc multiword shift `rcl dx,1 / rcl word ss:[0x607],1` (x6): under
              // FIX A's blind-invalidate each rcl store cleared the line, so the NEXT rcl load
              // MISSED and re-filled STALE from the backing before the store's write-through was
              // globally visible -> the high word never accumulated -> COMMAND.COM's LBA 0x2F3C0
              // truncated to 0x0F3C0 (62400) -> Win95 shell load fails. Byte map = ven_axi_master's
              // (ven_axi_master.sv:186): the byte at c_addr is lane 0 of c_wstrb/c_wdata, so byte i
              // lands at line byte offset c_addr[4:0]+i (a within-line cross-WORD store — e.g.
              // [0x607] at offset 23 spanning 23,24 — is handled naturally; xline stores that spill
              // to the NEXT line keep the blind-invalidate arm below). The store is still
              // write-through (comb driver), so the backing stays authoritative.
              for (int i = 0; i < 4; i++)
                if (c_wstrb[i])
                  dc_line[{set_c, hit_way}][8*(c_addr[4:0] + i[4:0]) +: 8] <= c_wdata[8*i +: 8];
              dc_val[set_c][~hit_way] <= 1'b0;   // defensively drop any stale alias in the other way
              dc_lru[set_c] <= hit_way;
            end else begin
              // FIX A (Win95 relocation coherence, build #16): WRITE MISS or cross-line -> BLIND-
              // invalidate BOTH ways of every set the store touches. The DCACHE has NO external-write
              // snoop (g_nol2, ventium_l1_axi.sv:443); the hardware-proven failure is a source load of
              // 0xb00 served stale 0x00000000 from a valid way-1 HIT while DDR held CODE (06 8b 4e 68).
              // A hit-only invalidate (build #13) cannot catch a stale line the store MISSED, so clear
              // BOTH ways: if the store MISSED a stale line (filled later) the set is clean so a
              // subsequent read MISS re-fills committed DDR (write-through already waited BVALID). Also
              // subsumes the xline __call16 iret-frame case (addressed + spilled-into lines cleared).
              dc_val[set_c][0] <= 1'b0;
              dc_val[set_c][1] <= 1'b0;
              if (xline) begin dc_val[set_n][0] <= 1'b0; dc_val[set_n][1] <= 1'b0; end
            end
            // (STLD write-capture removed with the forwarding buffer.)
          end
        end
        L1_FILL: begin
          // H-06/H-07: an invalidation arriving MID-fill (beats 0..6) has no allocated
          // line to match, so it must be remembered instead of dropped.
          if (flush_all || snoop_hits_fill) fill_poison <= 1'b1;
          if (m_ack) begin
            // capture the returned word: into the PRIVATE buffer for a non-cacheable
            // bypass (no array write), else into the victim line being allocated.
            // REVIEW2_aug2 C-09: A BYPASS BEAT MUST NEVER WRITE THE ARRAY.
            //
            // This used to read `if (bypass_q && !byp_hi_beat) ... else dc_line ...`,
            // so the NINTH (high-word) beat of a cross-line non-cacheable read -- where
            // bypass_q=1 AND byp_hi_beat=1 -- failed the first condition and fell into
            // the array write. fw is still 7 at that point, so the returned word was
            // written into victim word 7 of {fset,fway} with NO tag or valid update: a
            // valid, unrelated line silently corrupted beneath its existing tag, which
            // a later hit then serves as if it were real data.
            //
            // A bypass allocates nothing by definition, so the array write is gated on
            // !bypass_q rather than on the beat index. The high word is captured as
            // bp_hi immediately below.
            if (bypass_q) begin
              if (!byp_hi_beat) bp_line[{fw,5'b00000} +: 32] <= m_rdata;
            end else begin
              dc_line[{fset,fway}][{fw,5'b00000} +: 32] <= m_rdata;
            end
            if (byp_hi_beat) begin
              // H-19: the extra request returns the NEXT line's word 0, which is beat 0
              // of that request.
              //
              // ---- REVIEW2_aug2 C-09 (second half): DRAIN THE REST OF THE BURST.
              // This used to capture beat 0 and jump straight to L1_BYP, leaving SEVEN
              // beats of that burst outstanding on the backing interface. ven_axi_master
              // turns every read into an eight-beat line burst -- it cannot request a
              // single word -- and the seam carries no transaction ID, so if the core
              // started another miss before those beats drained, the new L1_FILL
              // consumed the OLD burst's residual data as its own line. Silent, and it
              // corrupts a line that was filled correctly as far as any tag can tell.
              //
              // The review offers two fixes: a real single-beat backing operation, or
              // drain and identify the transaction before allowing a new fill. The
              // first needs a new request size on the ven_axi_master seam; this is the
              // second, and it is contained entirely in this state. fw is reused as the
              // drain counter (it is dead once the line is captured), so only word 0 is
              // taken and beats 1..7 are consumed and discarded before L1_BYP.
              if (fw == 3'd0) bp_hi <= m_rdata;
              if (fw == 3'(WORDS-1)) begin
                byp_hi_beat <= 1'b0;
                st          <= L1_BYP;
              end else fw <= fw + 3'd1;
            end else if (fw==3'(WORDS-1)) begin
              if (bypass_q) begin
                // non-cacheable: serve from bp_line next clock; allocate NOTHING.
                // H-19: unless the access crosses the line end, in which case run ONE
                // more beat for the following line's word 0 first.
                // C-09: restart fw at 0 so the high request's own eight beats are
                // counted and fully drained above.
                if (byp_need_hi) begin byp_hi_beat <= 1'b1; fw <= 3'd0; end
                else             st          <= L1_BYP;
              end else begin
                // last word → allocate the victim (tag/val) + MRU, then retry hits.
                // REVIEW Aug-1 H-06/H-07: only VALIDATE if the transaction was never
                // poisoned -- and re-test flush/snoop on this very clock too, because a
                // same-cycle invalidation cannot be caught by the pre-edge guards in the
                // flush/snoop blocks below (they see valid=0 for this not-yet-allocated
                // line). The tag is written either way; val is what gates it.
                dc_tag[fset][fway]<=ftag; dc_lru[fset]<=fway;
                dc_val[fset][fway]<= !(fill_poison || flush_all || snoop_hits_fill);
                st<=L1_DONE;
              end
            end else fw<=fw+3'd1;
          end
        end
        L1_DONE: begin
          // one settle clock so the just-written line is visible to the comb read
          // before the core's retry samples the hit. Then back to serving.
          st<=L1_IDLE;
        end
        L1_BYP: begin
          // non-cacheable read: c_ack + c_rdata (from bp_line) are asserted
          // combinationally THIS clock; just return to serving. Nothing allocated.
          st<=L1_IDLE;
        end
        default: st<=L1_IDLE;
      endcase
      // #35 external flush: clear every valid bit (last-write-wins over the case's
      // tag/val writes, so an invalidation always takes priority). The next reads
      // miss + refill the now-current backing. Tags/data are left (val gates them).
      if (flush_all)
        for (int s=0;s<L1_SETS;s++) begin dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0; end
      // golden mode: after each completed transaction, invalidate every line AND
      // clear the registered read window (rd_armed/rd_window_q/rd_addr_q) so the next
      // access fully re-fills + re-captures. Last-write-wins over the fill's val=1 and
      // the do_rd_cap capture above (this clock the txn already acked, so dropping the
      // state cannot un-do the ack — c_ack/rd_match are registered values sampled now).
      if (txn_done) begin
        rd_armed <= 1'b0; rd_window_q <= '0; rd_addr_q <= 32'd0;
        for (int s=0;s<L1_SETS;s++) begin dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0; end
      end
      // per-line snoop INVALIDATE (DMA / PCI coherence): clear the matching {set,way}
      // valid bit if resident. LAST in the FF so an invalidation wins over a same-cycle
      // allocate of that line (a DMA write must never leave a stale cached copy). Gated
      // by snoop_inv_valid — tied 0 in modes 0/1, so the default path is byte-identical.
      if (snoop_inv_valid) begin
        logic [IDXW-1:0] snp_set; logic [TAGW-1:0] snp_tag;
        snp_set = snoop_inv_addr[OFFW +: IDXW];
        snp_tag = snoop_inv_addr[OFFW+IDXW +: TAGW];
        if (dc_val[snp_set][0] && dc_tag[snp_set][0]==snp_tag) dc_val[snp_set][0]<=1'b0;
        if (dc_val[snp_set][1] && dc_tag[snp_set][1]==snp_tag) dc_val[snp_set][1]<=1'b0;
      end
    end
  end

`ifdef VEN_DBG_CORE
  // DEADLOCK detector (Quake cs=0087:0x334 non-retiring stall): if the core holds a request with no ack
  // for a long time, the L1D/AXI is stuck servicing it. Log the address + memory-path state ONCE so the
  // deadlocking access (upper-memory/MMIO/out-of-range?) can be identified.
  logic [23:0] stuck_cnt = 24'd0;
  logic        stuck_shown = 1'b0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin stuck_cnt <= 24'd0; stuck_shown <= 1'b0; end
    else begin
      if ((c_req && !c_ack) || st != L1_IDLE) stuck_cnt <= stuck_cnt + 24'd1;
      else stuck_cnt <= 24'd0;
      if (stuck_cnt == 24'd500000 && !stuck_shown) begin
        stuck_shown <= 1'b1;
        $display("[L1DSTUCK] c_req=%b c_we=%b c_addr=%08x ws=%b cacheable=%b hit=%b rd_hit=%b st=%0d | m_req=%b m_we=%b m_addr=%08x m_ack=%b fbase=%08x fw=%0d bypass=%b",
                 c_req, c_we, c_addr, c_wstrb, cacheable, hit, rd_hit, st, m_req, m_we, m_addr, m_ack, fbase, fw, bypass_q);
      end
    end
  end
`endif

endmodule : ven_l1d
