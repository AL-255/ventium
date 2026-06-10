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
    input  logic [IC_TAGW-1:0] tch2_tag
);

  // Data array as packed 256-bit lines, FLAT-indexed {set,way} for clean RAM
  // inference (with IC_WAYS=2^IC_WAYW, {set,way} == set*IC_WAYS+way).
`ifdef VEN_IC_BRAM
  // +VEN_IC_BRAM: force the line store into Block RAM (RAMB36) to DISSOLVE the
  // distributed-RAM read-mux MUXF congestion. BRAM mandates a SYNCHRONOUS read,
  // so rd_lineA/B are REGISTERED here. The line store is REPLICATED (ic_line_a
  // serves port A, ic_line_b serves port B) so each is a single-read SDP BRAM.
  (* ram_style = "block" *) logic [IC_LINE*8-1:0] ic_line_a [IC_SETS*IC_WAYS];
  (* ram_style = "block" *) logic [IC_LINE*8-1:0] ic_line_b [IC_SETS*IC_WAYS];
  logic [IC_LINE-1:0] fill_be;
  assign fill_be = {{(IC_LINE-4){1'b0}}, 4'b1111} << fill_off;
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
    rd_lineA <= ic_line_a[{rd_setA, rd_wayA}];
    rd_lineB <= ic_line_b[{rd_setB, rd_wayB}];
  end
`else
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
        // canonical UltraScale byte-write-enable template (both replicated copies).
        for (int bl=0; bl<32; bl++) begin
          if (fill_be[bl]) begin
            ic_line_a[{fill_set,fill_way}][bl*8 +: 8] <= fill_data[(bl%4)*8 +: 8];
            ic_line_b[{fill_set,fill_way}][bl*8 +: 8] <= fill_data[(bl%4)*8 +: 8];
          end
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
    end
  end

endmodule : icache
