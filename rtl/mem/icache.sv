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
// Behaviour-preserving extraction (R2): the inline ic_data/ic_tag/ic_val/ic_lru
// arrays, the per-word line fill, the fill-complete MRU set, the up-to-3 LRU
// touch ports, and the synchronous reset loop were lifted out of core.sv
// VERBATIM. The arrays are EXPOSED READ-ONLY as outputs (ic_data_o/ic_tag_o/
// ic_val_o/ic_lru_o) so the spine keeps its ~10 simultaneous combinational
// probes (ic_present / ic_byte / ic_hit_way / pf_miss_fa) UNCHANGED — they read
// the registered arrays directly off these outputs, reflecting PRE-edge state in
// the SAME clock a posedge fill/touch updates them (the ic_present/ic_byte-vs-
// next-edge-fill read-before-write that func diff cannot see). All writes land on
// posedge here.
//
// STALE-BY-DESIGN: a speculative V-decode reads ic_data for a NON-RESIDENT line
// (ic_byte returns whatever is in the array); the data is NEVER cleared on a
// miss/invalidate — only ic_val gates correctness. No "tidy-up" clearing.
//
// WRITE PORTS (each at most one transaction/clock, mutually exclusive arms in the
// spine FSM, so the inline NBA timing/priority is preserved):
//   * fill: one 32-bit word -> ic_data[fill_set][fill_way][fill_off +0..+3]. Fed
//     by S_PF (words 0..7 of the line covering pf_fill_addr) AND the S_PIPE-miss
//     word-0 path (different FSM arms => never concurrent). pf_fill_addr/
//     pf_fill_way/pf_word + the victim (~ic_lru_o) STAY in the spine and drive
//     this port; the module does NOT recompute the victim.
//   * fill_done: on the last fill word (S_PF, pf_word==7) allocate the chosen
//     2-way victim and mark it MRU (ic_tag[set][way]=tag; ic_val[set][way]=1;
//     ic_lru[set]=way) — oracle l1_access() miss path.
//   * up to 3 LRU touch ports (U / U-straddle / V) — a confirmed-HIT MRU update
//     (ic_lru[set] = hit way), applied in textual LAST-WRITE-WINS order (tch0
//     then tch1 then tch2) so several touches to the SAME set in one clock keep
//     the inline last-assignment priority EXACTLY. Each maps the old ic_touch()
//     (scan the set's two ways, set lru to whichever way holds the line).
//
// set = addr[11:5] (128 sets), off = addr[4:0] (byte in line), tag = addr[31:12]
// — VERBATIM. This is the SEPARATE fast-path I-cache; the slow-FSM fetch buffer
// (ibuf[16] in the spine) is untouched.

module icache #(
    parameter int IC_SETS = 128,
    parameter int IC_LINE = 32
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- READ-ONLY array outputs: the spine's combinational probes (ic_present /
    // ic_hit_way / ic_byte) read these directly, reflecting the REGISTERED PRE-edge
    // state this clock (the fill/touch below land on posedge). The speculative
    // V-decode reads of NON-RESIDENT lines keep returning stale ic_data_o; only
    // ic_val_o gates correctness.
    output logic [7:0]  ic_data_o [IC_SETS][2][IC_LINE],
    output logic [19:0] ic_tag_o  [IC_SETS][2],
    output logic        ic_val_o  [IC_SETS][2],
    output logic        ic_lru_o  [IC_SETS],

    // ---- Per-word fill: write one 32-bit word as 4 bytes into ic_data at
    // [fill_set][fill_way][fill_off +0..+3]. fill_set/fill_way/fill_off are
    // sequenced by the spine (pf_fill_addr/pf_fill_way/pf_word for S_PF; pf_miss_fa
    // /victim/0 for the S_PIPE word-0 path). At most one fill/clock.
    input  logic        fill_en,
    input  logic [6:0]  fill_set,
    input  logic        fill_way,
    input  logic [4:0]  fill_off,
    input  logic [31:0] fill_data,

    // ---- Fill complete (last word of an S_PF line, pf_word==7): allocate the
    // chosen victim way (tag/val) and mark it MRU. fill_done implies fill_en.
    input  logic        fill_done,
    input  logic [19:0] fill_tag,

    // ---- Up to 3 confirmed-HIT LRU touch ports (U / U-straddle / V), applied in
    // textual order tch0 -> tch1 -> tch2 (LAST-WRITE-WINS for same-set touches).
    // Each scans the set's two ways and sets ic_lru[set] to the way that holds
    // tch*_tag — the old ic_touch(addr) with set=addr[11:5], tag=addr[31:12].
    input  logic        tch0_en,
    input  logic [6:0]  tch0_set,
    input  logic [19:0] tch0_tag,
    input  logic        tch1_en,
    input  logic [6:0]  tch1_set,
    input  logic [19:0] tch1_tag,
    input  logic        tch2_en,
    input  logic [6:0]  tch2_set,
    input  logic [19:0] tch2_tag
);

  logic [7:0]  ic_data [IC_SETS][2][IC_LINE];
  logic [19:0] ic_tag  [IC_SETS][2];   // addr[31:12]
  logic        ic_val  [IC_SETS][2];
  logic        ic_lru  [IC_SETS];      // 2-way LRU: way most-recently-used (== D$)

  // READ-ONLY array outputs (combinational mirror of the registered arrays).
  always_comb begin
    for (int s=0; s<IC_SETS; s++) begin
      ic_lru_o[s] = ic_lru[s];
      for (int w=0; w<2; w++) begin
        ic_tag_o[s][w] = ic_tag[s][w];
        ic_val_o[s][w] = ic_val[s][w];
        for (int b=0; b<IC_LINE; b++) ic_data_o[s][w][b] = ic_data[s][w][b];
      end
    end
  end

  // LRU touch body (confirmed HIT): set the set's LRU to whichever of the two
  // ways holds `tag`. VERBATIM the old ic_touch() scan.
  task automatic do_touch(input logic [6:0] set, input logic [19:0] tag);
    for (int w=0; w<2; w++)
      if (ic_val[set][w] && ic_tag[set][w]==tag) ic_lru[set]<=w[0];
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // VERBATIM reset loop (I-cache empty out of reset; data left X — only val
      // gates correctness, matching the inline reset which cleared lru/val/tag).
      for (int s=0;s<IC_SETS;s++) begin
        ic_lru[s]<=1'b0;
        ic_val[s][0]<=1'b0; ic_val[s][1]<=1'b0;
        ic_tag[s][0]<=20'd0; ic_tag[s][1]<=20'd0;
      end
    end else begin
      // ---- per-word line fill (S_PF + S_PIPE word-0 path; one/clock) ----
      if (fill_en) begin
        ic_data[fill_set][fill_way][fill_off+5'd0]<=fill_data[7:0];
        ic_data[fill_set][fill_way][fill_off+5'd1]<=fill_data[15:8];
        ic_data[fill_set][fill_way][fill_off+5'd2]<=fill_data[23:16];
        ic_data[fill_set][fill_way][fill_off+5'd3]<=fill_data[31:24];
        if (fill_done) begin
          // oracle l1_access() miss path: val[victim]=1; tag[victim]=tag;
          // lru=victim. (fill_done implies fill_en.)
          ic_tag[fill_set][fill_way]<=fill_tag;
          ic_val[fill_set][fill_way]<=1'b1;
          ic_lru[fill_set]<=fill_way;
        end
      end
      // ---- up to 3 LRU touches, textual LAST-WRITE-WINS (U then straddle then V).
      // A fill_done MRU-set and a same-set touch never coincide (fill is S_PF, the
      // touches are S_PIPE issue arms — mutually exclusive FSM states), so the
      // ordering here vs the fill above replicates the inline per-arm sequencing.
      if (tch0_en) do_touch(tch0_set, tch0_tag);
      if (tch1_en) do_touch(tch1_set, tch1_tag);
      if (tch2_en) do_touch(tch2_set, tch2_tag);
    end
  end

endmodule : icache
