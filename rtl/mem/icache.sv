// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/icache.sv — L1 instruction cache ARRAYS + fill + LRU-touch
//                 (extracted from core.sv, R2; behaviour-preserving).
//
// PLAN.md §6.1 (Front end) / PLAN §2 "Memory subsystem": 8 KB, 2-way
// set-associative, 32-byte line => 128 sets, 2-way LRU. Geometry matches the
// cycle oracle verif/qemu-plugins/p5trace.c (L1_SETS=128/L1_WAYS=2/L1_LINE=32,
// l1_access 2-way LRU). Key reference: Alpert & Avnon IEEE Micro 1993 p.5 (L1
// organisation); Pentium Dev. Manual Vol.1 (241428) ch.3 (cache).
//
// PARAMETRIC GEOMETRY (IC_SETS / IC_WAYS / IC_LINE): the default 128 sets × 2
// ways is the silicon geometry and the cycle-validated config. IC_WAYS is
// generalised to any power of two (>=2) by a per-way **age-counter true LRU**
// that reduces EXACTLY to the original 2-way behaviour at IC_WAYS==2 (same hit
// test, same victim sequence, same touch/fill recency update) — so the default
// build stays bit/cycle-identical. Non-2-way geometries are functionally correct
// but not matched by the fixed-2-way p5trace.so cycle oracle (area/perf
// experiments). The line store is flat-indexed {set,way}; with IC_WAYS=2^IC_WAYW
// this is exactly set*IC_WAYS+way, so RAM inference is unchanged at the default.
//
// The 2-way "MRU way" of old is replaced by ic_age[set][way] (recency rank, 0 =
// MRU .. IC_WAYS-1 = LRU). The replacement VICTIM (LRU way) is exposed as
// ic_victim_o so the spine's fill-way selection stays uniform (== ~ic_lru at
// 2-way). The data array, fill, and touch ports are otherwise VERBATIM.
//
// Behaviour-preserving extraction (R2): the inline ic_data/ic_tag/ic_val arrays,
// the per-word line fill, the fill-complete MRU set, the up-to-3 LRU touch ports,
// and the synchronous reset loop were lifted out of core.sv. The arrays are
// EXPOSED READ-ONLY as outputs (rd_lineA/B/ic_tag_o/ic_val_o/ic_victim_o) so the
// spine keeps its combinational probes (ic_present / ic_byte / ic_hit_way) — they
// read the registered arrays directly off these outputs, reflecting PRE-edge
// state in the SAME clock a posedge fill/touch updates them. All writes land on
// posedge here.
//
// STALE-BY-DESIGN: a speculative V-decode reads ic_data for a NON-RESIDENT line
// (ic_byte returns whatever is in the array); the data is NEVER cleared on a
// miss/invalidate — only ic_val gates correctness. No "tidy-up" clearing.
//
// set = addr[5 +: IC_IDXW], off = addr[4:0] (byte in line), tag = addr[5+IC_IDXW
// +: IC_TAGW]. This is the SEPARATE fast-path I-cache; the slow-FSM fetch buffer
// (ibuf[16] in the spine) is untouched.

module icache #(
    parameter int IC_SETS = 128,
    parameter int IC_LINE = 32,
    parameter int IC_WAYS = 2,
    // Derived geometry: index width = log2(sets), tag width = 32-5-idx (the line
    // offset is always 5 bits / 32 B), way-index width = log2(ways) (>=1).
    parameter int IC_IDXW = $clog2(IC_SETS),
    parameter int IC_TAGW = 32 - 5 - IC_IDXW,
    parameter int IC_WAYW = (IC_WAYS <= 1) ? 1 : $clog2(IC_WAYS)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- READ-ONLY array outputs: ic_tag/val/victim stay small combinational
    // mirrors (the spine's ic_present/ic_hit_way probes + the fill-way selection
    // read them directly, PRE-edge). The DATA array is read through TWO ADDRESSED
    // async line ports (the fetch window spans at most 2 consecutive 32-byte
    // lines), so Vivado infers distributed RAM.
    input  logic [IC_IDXW-1:0]  rd_setA, // line A = the fetch line (flin[idx])
    input  logic [IC_WAYW-1:0]  rd_wayA,
    output logic [IC_LINE*8-1:0] rd_lineA,
    input  logic [IC_IDXW-1:0]  rd_setB, // line B = the next line (for straddles)
    input  logic [IC_WAYW-1:0]  rd_wayB,
    output logic [IC_LINE*8-1:0] rd_lineB,
    // KV260 silicon fix: each registered BRAM read asserts its collide flag when the
    // read launched in the SAME cycle a fill WROTE the SAME {set,way}. On real SDP
    // RAMB36 a cross-port read-during-write returns INVALID data (Verilator models a
    // clean READ_FIRST, so it never sees this) — the spine must NOT consume a buffer
    // whose read collided; it forces a clean re-read instead. Tied 0 on the async
    // (distributed-RAM) path, which has no registered read and no collision.
    output logic        rd_collA,
    output logic        rd_collB,
    output logic [IC_TAGW-1:0] ic_tag_o   [IC_SETS][IC_WAYS],
    output logic        ic_val_o   [IC_SETS][IC_WAYS],
    output logic [IC_WAYW-1:0] ic_victim_o [IC_SETS],   // replacement (LRU) way per set

    // ---- Per-word fill: write one 32-bit word as 4 bytes into ic_data at
    // [fill_set][fill_way][fill_off +0..+3]. At most one fill/clock.
    input  logic        fill_en,
    input  logic [IC_IDXW-1:0]  fill_set,
    input  logic [IC_WAYW-1:0]  fill_way,
    input  logic [4:0]  fill_off,
    input  logic [31:0] fill_data,

    // ---- Fill complete (last word of an S_PF line, pf_word==7): allocate the
    // chosen victim way (tag/val) and mark it MRU. fill_done implies fill_en.
    input  logic        fill_done,
    input  logic [IC_TAGW-1:0] fill_tag,

    // ---- Up to 3 confirmed-HIT LRU touch ports (U / U-straddle / V), applied in
    // textual order tch0 -> tch1 -> tch2 (LAST-WRITE-WINS for same-set touches).
    input  logic        tch0_en,
    input  logic [IC_IDXW-1:0]  tch0_set,
    input  logic [IC_TAGW-1:0] tch0_tag,
    input  logic        tch1_en,
    input  logic [IC_IDXW-1:0]  tch1_set,
    input  logic [IC_TAGW-1:0] tch1_tag,
    input  logic        tch2_en,
    input  logic [IC_IDXW-1:0]  tch2_set,
    input  logic [IC_TAGW-1:0] tch2_tag,

    // ---- per-line snoop INVALIDATE (DMA / PCI coherence, the EADS#/inquire
    // analogue): the northbridge pulses this for one clock when a non-CPU master
    // writes a line that may hold code (e.g. a program DMA'd in then executed), so
    // the next fetch of it misses and refills. Clears the matching {set,way} valid
    // bit if resident; harmless if absent. Tied 0 until DMA is a coherent requester
    // (Phase D) → the default build is byte-identical.
    input  logic        snoop_inv_valid,
    input  logic [31:0] snoop_inv_addr
);

  // Data array as packed 256-bit lines, FLAT-indexed {set,way} for clean RAM
  // inference (with IC_WAYS=2^IC_WAYW, {set,way} == set*IC_WAYS+way).
`ifdef VEN_IC_BRAM
  // +VEN_IC_BRAM: force the line store into Block RAM (RAMB36) to DISSOLVE the
  // distributed-RAM read-mux MUXF congestion. BRAM mandates a SYNCHRONOUS read,
  // so rd_lineA/B are REGISTERED here. The line store is REPLICATED (ic_line_a
  // serves port A, ic_line_b serves port B) so each is a single-write/single-read
  // SDP BRAM. This two-array structure is the form PROVEN to run the core: each
  // 256-bit port maps to its own four physical RAMB36 slices (one per 64-bit lane).
  //
  // SYNTH-ONLY HAZARD (KV260 silicon bug, GLS-reproduced): if the two stores are
  // written with byte-IDENTICAL data+address, Vivado's RAM-equivalence pass PROVES
  // ic_line_a == ic_line_b and eliminates one array — tying ic_line_a's write
  // enables to 0 and deriving rd_lineA from ic_line_b. The leftover degenerate
  // ic_line_a then DECLONES ("[Synth 8-223] decloning ... RAMB36E2") down to a
  // single 64-bit RAMB36 fanned across all four lanes of rd_lineA
  // (`assign rd_lineA[255:192] = rd_lineA[191:128]` in funcsim), so every lane
  // returns the SAME 64-bit slice and the upper word of an 8-byte granule
  // (addr bit[2]=1) reads back the lower word's bytes => board-only fetch
  // corruption. Functional Verilator never models this (the arrays are genuinely
  // separate in RTL).
  //
  // ANTI-DECLONE (METHOD B — word-order skew): attributes alone (dont_touch / keep
  // / ram_style=block) do NOT stop the equivalence merge, and per-lane address /
  // data skews either dump the array to LUTRAM or mis-synthesise the A port. So we
  // make ic_line_b GENUINELY non-equivalent in STORED CONTENT: it holds each line
  // with its eight 32-bit WORDS in REVERSED order (word w stored at word slot 7-w).
  // The write stays a single direct-offset byte-write to the reversed word slot —
  // reversed offset = fill_off XOR 5'b11100 (== 28-fill_off for the word-aligned
  // fill_off), which is direct line-offset indexing, so the byte-write BRAM template
  // is preserved (a byte-SCATTER reversal instead breaks it -> LUTRAM). ic_line_a
  // and ic_line_b now store DIFFERENT bit patterns for every non-palindromic line,
  // so Vivado cannot prove them equal, keeps BOTH writes, declones NOTHING, and
  // infers 8 RAMB36E2 (4 per array). The rd_lineB read un-reverses the words, so
  // behaviour is bit-identical to the original. Pure wiring (a static word swizzle).
  localparam logic [4:0] WREV = 5'b11100; // reversed word offset = fill_off ^ WREV
  (* ram_style = "block" *) logic [IC_LINE*8-1:0] ic_line_a [IC_SETS*IC_WAYS];
  (* ram_style = "block" *) logic [IC_LINE*8-1:0] ic_line_b [IC_SETS*IC_WAYS];
  logic [IC_LINE*8-1:0] rdq_b_rev;  // registered RAW (word-reversed) read of ic_line_b
  logic [IC_LINE-1:0] fill_be;    // byte-enable for ic_line_a (natural word offset)
  logic [IC_LINE-1:0] fill_be_b;  // byte-enable for ic_line_b (reversed word offset)
  assign fill_be   = {{(IC_LINE-4){1'b0}}, 4'b1111} <<  fill_off;
  assign fill_be_b = {{(IC_LINE-4){1'b0}}, 4'b1111} << (fill_off ^ WREV);
`else
  // Default: distributed RAM — the ram_style hint pushes Vivado to LUTRAM (async
  // read + partial word write) instead of flip-flops + read muxes.
  (* ram_style = "distributed" *)
  logic [IC_LINE*8-1:0] ic_line [IC_SETS*IC_WAYS];
`endif
  logic [IC_TAGW-1:0] ic_tag  [IC_SETS][IC_WAYS];   // addr[31:5+idx]
  logic               ic_val  [IC_SETS][IC_WAYS];
  logic [IC_WAYW-1:0] ic_age  [IC_SETS][IC_WAYS];   // recency rank: 0=MRU .. WAYS-1=LRU

`ifdef VEN_IC_BRAM
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // Pin the BRAM output registers out of reset. On silicon these power up to
      // arbitrary values; with no reset a fetch that samples them before the read
      // settles (the registered-read latency window) consumes garbage -> opcode
      // misdecode. Zero is the safe value (decodes the same as the zero-init sim
      // that make verify uses), so this removes the synth/sim divergence.
      rd_lineA  <= '0;
      rdq_b_rev <= '0;
      rd_collA  <= 1'b0;
      rd_collB  <= 1'b0;
    end else begin
      rd_lineA  <= ic_line_a[{rd_setA, rd_wayA}];
      // CLEAN whole-line registered read of ic_line_b (keeps the BRAM read port);
      // ic_line_b holds the words reversed, so rdq_b_rev is the reversed line.
      rdq_b_rev <= ic_line_b[{rd_setB, rd_wayB}];
      // collide flags: this read launches off {rd_set*,rd_way*}; if the fill writes
      // that exact {set,way} THIS cycle, the registered data will be BRAM-garbage on
      // silicon. Register the flag in lock-step so the spine can reject the buffer.
      rd_collA  <= fill_en && ({rd_setA, rd_wayA} == {fill_set, fill_way});
      rd_collB  <= fill_en && ({rd_setB, rd_wayB} == {fill_set, fill_way});
    end
  end
  // un-reverse the eight words COMBINATIONALLY (after the registered BRAM read) so
  // rd_lineB is bit-identical to the unreversed line. Pure wiring, no logic depth.
  always_comb
    for (int wd=0; wd<8; wd++) rd_lineB[wd*32 +: 32] = rdq_b_rev[(7-wd)*32 +: 32];
`ifdef VEN_IC_COLLIDE_DBG
  // DIAGNOSTIC (sim-only, default OFF): detect the cross-port read-during-write
  // collision the board RAMB36 cannot model — fill writes {fill_set,fill_way} in the
  // SAME cycle the registered read launches off the SAME {set,way}. Verilator captures
  // the OLD line (clean READ_FIRST); real SDP BRAM returns INVALID data. Classify by
  // whether the colliding way is RESIDENT (val=1 => the read is CONSUMED => dangerous).
  int unsigned colA_tot, colA_live, colB_tot, colB_live;
  always_ff @(posedge clk) begin
    if (!rst_n) begin colA_tot<=0; colA_live<=0; colB_tot<=0; colB_live<=0; end
    else if (fill_en) begin
      if ({rd_setA,rd_wayA} == {fill_set,fill_way}) begin
        colA_tot <= colA_tot + 1;
        if (ic_val[fill_set][fill_way]) colA_live <= colA_live + 1;
        if (colA_tot < 12) $display("[ICCOL-A] set=%0d way=%0d off=%0d val=%b done=%b @%0t",
                                    fill_set, fill_way, fill_off, ic_val[fill_set][fill_way], fill_done, $time);
      end
      if ({rd_setB,rd_wayB} == {fill_set,fill_way}) begin
        colB_tot <= colB_tot + 1;
        if (ic_val[fill_set][fill_way]) colB_live <= colB_live + 1;
        if (colB_tot < 12) $display("[ICCOL-B] set=%0d way=%0d off=%0d val=%b done=%b @%0t",
                                    fill_set, fill_way, fill_off, ic_val[fill_set][fill_way], fill_done, $time);
      end
    end
  end
  final $display("[ICCOL-SUMMARY] portA: total=%0d live(resident)=%0d  portB: total=%0d live=%0d",
                 colA_tot, colA_live, colB_tot, colB_live);
`endif
`else
  // Async distributed-RAM path: combinational read, no registered-read collision.
  assign rd_collA = 1'b0;
  assign rd_collB = 1'b0;
  assign rd_lineA = ic_line[{rd_setA, rd_wayA}];
`ifdef VEN_IC_NARROWB
  // +VEN_IC_NARROWB: rd_lineB is the NEXT (straddle) line, sliced only at LOW byte
  // positions, so drive only the LOW 128 bits and prune the high read mux.
  assign rd_lineB = {128'd0, ic_line[{rd_setB, rd_wayB}][127:0]};
`else
  assign rd_lineB = ic_line[{rd_setB, rd_wayB}];
`endif
`endif // VEN_IC_BRAM

  // READ-ONLY tag/val mirrors + the per-set replacement (LRU) victim way.
  always_comb begin
    for (int s=0; s<IC_SETS; s++) begin
      ic_victim_o[s] = '0;
      for (int w=0; w<IC_WAYS; w++) begin
        ic_tag_o[s][w] = ic_tag[s][w];
        ic_val_o[s][w] = ic_val[s][w];
        if (ic_age[s][w] == IC_WAYW'(IC_WAYS-1)) ic_victim_o[s] = IC_WAYW'(w);
      end
    end
  end

  // Recency update for an access (hit or fill) to way k of `set`: every way
  // more-recent than k ages by one, and k becomes MRU. Reduces to "ic_lru<=k"
  // at IC_WAYS==2.
  task automatic touch_way(input logic [IC_IDXW-1:0] set, input logic [IC_WAYW-1:0] k);
    logic [IC_WAYW-1:0] old_a;
    old_a = ic_age[set][k];
    for (int w=0; w<IC_WAYS; w++)
      if (ic_age[set][w] < old_a) ic_age[set][w] <= ic_age[set][w] + 1'b1;
    ic_age[set][k] <= '0;
  endtask

  // LRU touch body (confirmed HIT): make the way holding `tag` the MRU.
  task automatic do_touch(input logic [IC_IDXW-1:0] set, input logic [IC_TAGW-1:0] tag);
    for (int w=0; w<IC_WAYS; w++)
      if (ic_val[set][w] && ic_tag[set][w]==tag) touch_way(set, IC_WAYW'(w));
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // I-cache empty out of reset (data left X — only val gates correctness).
      // age = way index => initial victim (max age) = way IC_WAYS-1, matching the
      // old reset (ic_lru=0 => victim=~0=way1) at 2-way.
      for (int s=0;s<IC_SETS;s++)
        for (int w=0;w<IC_WAYS;w++) begin
          ic_val[s][w]<=1'b0; ic_tag[s][w]<='0; ic_age[s][w]<=IC_WAYW'(w);
        end
    end else begin
      // ---- per-word line fill (S_PF + S_PIPE word-0 path; one/clock) ----
      if (fill_en) begin
`ifdef VEN_IC_BRAM
        // canonical UltraScale byte-write-enable template. ic_line_a uses the
        // natural byte-enable (fill_be); ic_line_b uses the reversed-word byte-enable
        // (fill_be_b) so the same fill_data word lands at word slot 7-w => ic_line_b
        // stores the line word-reversed. Both are direct line-offset byte-writes, so
        // both stay byte-write BRAMs; the differing content prevents the declone.
        for (int bl=0; bl<32; bl++) begin
          if (fill_be[bl])   ic_line_a[{fill_set,fill_way}][bl*8 +: 8] <= fill_data[(bl%4)*8 +: 8];
          if (fill_be_b[bl]) ic_line_b[{fill_set,fill_way}][bl*8 +: 8] <= fill_data[(bl%4)*8 +: 8];
        end
`else
        ic_line[{fill_set,fill_way}][{fill_off,3'b000} +: 32] <= fill_data;
`endif
        if (fill_done) begin
          // oracle l1_access() miss path: val[victim]=1; tag[victim]=tag; MRU=victim.
          ic_tag[fill_set][fill_way]<=fill_tag;
          ic_val[fill_set][fill_way]<=1'b1;
          touch_way(fill_set, fill_way);
        end
      end
      // ---- up to 3 LRU touches, textual LAST-WRITE-WINS (U then straddle then V).
      if (tch0_en) do_touch(tch0_set, tch0_tag);
      if (tch1_en) do_touch(tch1_set, tch1_tag);
      if (tch2_en) do_touch(tch2_set, tch2_tag);
      // per-line snoop INVALIDATE — LAST in the FF so it wins over a same-cycle
      // fill_done allocate of that line (a DMA write must not leave stale code cached).
      // Gated by snoop_inv_valid (tied 0 in the default build → byte-identical).
      if (snoop_inv_valid) begin
        logic [IC_IDXW-1:0] snp_set; logic [IC_TAGW-1:0] snp_tag;
        snp_set = snoop_inv_addr[5 +: IC_IDXW];
        snp_tag = snoop_inv_addr[5+IC_IDXW +: IC_TAGW];
        for (int w=0; w<IC_WAYS; w++)
          if (ic_val[snp_set][w] && ic_tag[snp_set][w]==snp_tag) ic_val[snp_set][w] <= 1'b0;
      end
    end
  end

endmodule : icache
