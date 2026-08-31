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
// STORE: per (set,way) a line of NSLOT packed fpd_t + a 32-entry byte->slot map
// (a "valid boundary here" bit + the slot index). Registered (synchronous) reads
// so the arrays infer BRAM/URAM (the 64 idle URAMs) instead of a distributed-RAM
// read mux — mirrors the +VEN_IC_BRAM registered-line front-end timing exactly
// (valid the clock AFTER the address), replicated A/B for the two fetch-window
// lines. NSLOT=8: a 32-byte line of avg ~3-byte ops holds ~8 fast-path insns; a
// denser line (many 1-byte ops) overflows -> those offsets read slotmap.valid=0
// and the spine re-predecodes from that flin (a perf event, never a correctness
// one). This is the SYNTH-PROBE increment (P0-11): structure faithful + common-
// case correct so the equivalence gate runs; full SMC/partial-fill coherence and
// branch-into-middle re-walk are the follow-on (very-large) work.

module uopcache
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
#(
    parameter int IC_SETS = 128,
    parameter int IC_LINE = 32,
    parameter int NSLOT   = 8,       // fast-path insns covered per 32-byte line
    parameter int IC_IDXW = $clog2(IC_SETS)  // set-index width (7 full / 6 half)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- registered slot-read ports (mirror icache rd_lineA/rd_lineB timing:
    // present (set,way) on clock T, the slot line + byte->slot map are valid on
    // T+1).  Port A = flin's line; port B = the next (straddle) line.
    input  logic [IC_IDXW-1:0]  rd_setA,
    input  logic        rd_wayA,
    output fpd_t        rd_slotsA [NSLOT],
    output logic        rd_bvalidA [IC_LINE],   // byte-offset is an insn boundary
    output logic [2:0]  rd_bslotA  [IC_LINE],   // ...and maps to this slot
    output logic        rd_pdvalidA,            // this line has been predecoded
    output logic [IC_IDXW-1:0] rd_setA_q,       // address belonging to A's registered data
    output logic        rd_wayA_q,
    input  logic [IC_IDXW-1:0]  rd_setB,
    input  logic        rd_wayB,
    output fpd_t        rd_slotsB [NSLOT],
    output logic        rd_bvalidB [IC_LINE],
    output logic [2:0]  rd_bslotB  [IC_LINE],
    output logic        rd_pdvalidB,
    output logic [IC_IDXW-1:0] rd_setB_q,       // address belonging to B's registered data
    output logic        rd_wayB_q,

    // ---- predecode trigger: the spine pulses pd_start from an instruction
    // boundary it has just slow-decoded.  `pd_off` is that known boundary within
    // the line.  A cache-line origin is NOT inherently a x86 instruction boundary:
    // the preceding instruction may straddle into byte 0, so walking blindly from
    // zero can manufacture a plausible but false later boundary.
    input  logic         pd_start,
    input  logic [IC_IDXW-1:0]   pd_set,
    input  logic         pd_way,
    input  logic [16*8-1:0] pd_bytes,  // trusted S_FETCH window, byte 0 = pd_off
    input  logic [$clog2(IC_LINE)-1:0] pd_off,
    input  logic [4:0]   pd_avail,     // trusted bytes in this line (1..16)
    input  logic [31:0]  pd_flags,
    input  logic         pd_cycle_mode,
    // invalidate a (set,way)'s predecode validity (refill/SMC) — the spine pulses
    // this on allocate so a stale predecode never reads back valid.
    input  logic         inv_en,
    input  logic [IC_IDXW-1:0]   inv_set,
    input  logic         inv_way,
    output logic         pd_busy
);

  localparam int FPDW = $bits(fpd_t);
  localparam logic [5:0] IC_LINE_W = 6'(IC_LINE);
  localparam logic [3:0] LAST_SLOT = 4'(NSLOT-1);

  // ---- predecoded store: NSLOT packed fpd_t per (set,way) + per-byte boundary
  // map (1 valid bit + 3-bit slot) + a per-line predecoded-valid bit.  Registered
  // reads (below) so these infer block RAM, NOT a distributed-RAM read mux.  The
  // A/B copies are written identically (one fill predecode writes both) so the two
  // registered read ports are each a single-read SDP RAM — same trick as ic_line_a/b.
  (* ram_style = "block" *) logic [NSLOT*FPDW-1:0] store_slots_a [IC_SETS*2];
  (* ram_style = "block" *) logic [NSLOT*FPDW-1:0] store_slots_b [IC_SETS*2];
  (* ram_style = "block" *) logic [IC_LINE*4-1:0]  store_bmap_a  [IC_SETS*2]; // {valid,slot[2:0]} x32
  (* ram_style = "block" *) logic [IC_LINE*4-1:0]  store_bmap_b  [IC_SETS*2];
  logic store_pdv [IC_SETS*2];     // small: keep in FF

  // ---- registered reads (valid the clock AFTER the address) -----------------
  logic [NSLOT*FPDW-1:0] rdslots_a_q, rdslots_b_q;
  logic [IC_LINE*4-1:0]  rdbmap_a_q,  rdbmap_b_q;
  logic                  rdpdv_a_q,   rdpdv_b_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rdpdv_a_q <= 1'b0; rdpdv_b_q <= 1'b0;
      rd_setA_q <= '1;   rd_setB_q <= '1;
      rd_wayA_q <= '1;   rd_wayB_q <= '1;
    end else begin
      rdslots_a_q <= store_slots_a[{rd_setA, rd_wayA}];
      rdslots_b_q <= store_slots_b[{rd_setB, rd_wayB}];
      rdbmap_a_q  <= store_bmap_a [{rd_setA, rd_wayA}];
      rdbmap_b_q  <= store_bmap_b [{rd_setB, rd_wayB}];
      rdpdv_a_q   <= store_pdv[{rd_setA, rd_wayA}];
      rdpdv_b_q   <= store_pdv[{rd_setB, rd_wayB}];
      rd_setA_q   <= rd_setA; rd_wayA_q <= rd_wayA;
      rd_setB_q   <= rd_setB; rd_wayB_q <= rd_wayB;
    end
  end

  // unpack the registered line into the slot/byte-map outputs.  The fast-path 8:1
  // slot mux (slots[slot]) lives in the SPINE, off these outputs.
  always_comb begin
    for (int s=0;s<NSLOT;s++) begin
      rd_slotsA[s] = rdslots_a_q[s*FPDW +: FPDW];
      rd_slotsB[s] = rdslots_b_q[s*FPDW +: FPDW];
    end
    for (int b=0;b<IC_LINE;b++) begin
      rd_bvalidA[b] = rdbmap_a_q[b*4+3];
      rd_bslotA[b]  = rdbmap_a_q[b*4 +: 3];
      rd_bvalidB[b] = rdbmap_b_q[b*4+3];
      rd_bslotB[b]  = rdbmap_b_q[b*4 +: 3];
    end
    rd_pdvalidA = rdpdv_a_q;
    rd_pdvalidB = rdpdv_b_q;
  end

  // ---- predecode walker (sequential; ~1 instruction/cycle) -------------------
  // Decodes the FIXED bottom 6 bytes of `residual`, records the slot + boundary,
  // then shifts `residual` right by the decoded length (the only variable op, a
  // <=48-bit barrel shift) and advances the byte offset.  It begins at pd_off,
  // an architectural instruction boundary supplied by the slow decoder.  No
  // flin-indexed wide byte select is reintroduced on the ISSUE path.
  typedef enum logic [1:0] { W_IDLE, W_WALK, W_WRITE } wstate_e;
  wstate_e               wst;
  logic [IC_LINE*8-1:0]  residual;     // line, shifted as bytes are consumed
  logic [5:0]            woff;         // current byte offset within the line (0..32)
  logic [5:0]            wlimit;       // exclusive trusted-byte limit within this line
  logic [3:0]            wslot;        // current slot index
  logic [IC_IDXW-1:0]     wset; logic wway;
  logic [31:0]           wflags; logic wcyc;

  // walker working buffers (written into the store on W_WRITE)
  logic [NSLOT*FPDW-1:0] wbuf_slots;
  logic [IC_LINE*4-1:0]  wbuf_bmap;

  // the decode leaf, fed the FIXED bottom 6 bytes of residual (no mux).
  fpd_t pd_uop;
  decode u_pd_decode (
      .ib0(residual[7:0]),   .ib1(residual[15:8]),  .ib2(residual[23:16]),
      .ib3(residual[31:24]), .ib4(residual[39:32]), .ib5(residual[47:40]),
      .iflags(wflags), .cycle_mode(wcyc), .uop(pd_uop)
  );

  // A decoded length is authoritative only for the fast-path subset.  `decode`
  // intentionally leaves unsupported instructions as {simple=0,len=1}; using
  // that placeholder to walk past (for example) CALL rel32 would poison every
  // later boundary in the line.  Record the unsupported boundary itself so it
  // safely falls back to S_DECODE, then stop; that slow decode re-seeds a new walk
  // at the true post-instruction EIP.
  logic [3:0] pd_len;
  logic       pd_known;
  logic       pd_fits;
  logic [5:0] pd_end;
  assign pd_len = (pd_uop.len==4'd0) ? 4'd1 : pd_uop.len;
  assign pd_known = pd_uop.simple || pd_uop.is_fp;
  assign pd_end = woff + {2'd0,pd_len};
  assign pd_fits = pd_known && (pd_end <= wlimit) &&
                   (pd_end <= IC_LINE_W);

  assign pd_busy = (wst != W_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wst <= W_IDLE;
      for (int i=0;i<IC_SETS*2;i++) store_pdv[i] <= 1'b0;
    end else begin
      // invalidate (refill/SMC): clear predecoded-valid for the (set,way).
      if (inv_en) store_pdv[{inv_set,inv_way}] <= 1'b0;

      unique case (wst)
        W_IDLE: begin
          if (pd_start) begin
            // A seeded suffix replaces the map for this (set,way).  Its read
            // ports are synchronous, so leave the old map invalid while the new
            // walk/write drains; otherwise a same-line redirect can consume one
            // clock of stale slots before the replacement read returns.
            store_pdv[{pd_set,pd_way}] <= 1'b0;
            residual   <= {128'd0,pd_bytes};
            woff       <= {1'b0,pd_off};
            wlimit     <= {1'b0,pd_off} + {1'b0,pd_avail};
            wslot      <= 4'd0;
            wset       <= pd_set;  wway <= pd_way;
            wflags     <= pd_flags; wcyc <= pd_cycle_mode;
            wbuf_slots <= '0;
            wbuf_bmap  <= '0;
            wst        <= W_WALK;
          end
        end
        W_WALK: begin
          // Record only instructions whose entire encoding is present in the
          // trusted S_FETCH window.  Unsupported or window-straddling operations
          // remain invalid and are decoded by the slow FSM, which seeds again at
          // the next architectural boundary.
          if (pd_fits) begin
            wbuf_slots[wslot*FPDW +: FPDW] <= pd_uop;
            wbuf_bmap[woff*4 +: 4] <= {1'b1, wslot[2:0]};
            residual <= residual >> {pd_len, 3'b000}; // drop pd_len bytes
            woff     <= woff + {2'd0, pd_len};
            wslot    <= wslot + 4'd1;
          end
          // Stop on an unknown/incomplete op, when trusted bytes end, when the
          // line ends, or when slot capacity is reached.  Invalid bytes are a
          // conservative performance miss, never a speculative decode.
          if (!pd_fits || (pd_end >= wlimit) ||
              (pd_end >= IC_LINE_W) || (wslot == LAST_SLOT))
            wst <= W_WRITE;
        end
        W_WRITE: begin
          store_slots_a[{wset,wway}] <= wbuf_slots;
          store_slots_b[{wset,wway}] <= wbuf_slots;
          store_bmap_a [{wset,wway}] <= wbuf_bmap;
          store_bmap_b [{wset,wway}] <= wbuf_bmap;
          store_pdv[{wset,wway}]     <= 1'b1;
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

endmodule : uopcache
