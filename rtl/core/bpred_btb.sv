// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/bpred_btb.sv — Branch prediction: 256-entry 4-way BTB + 2-bit predictor
//                     (extracted from core.sv, R2; behaviour-preserving).
//
// PLAN.md §6.1 (Front end) / PLAN §2 "Branch prediction": a 256-entry, 4-way
// set-associative BTB (64 sets) with 2-bit/4-state saturating counters,
// accessed in D1. Policy: BTB-miss => predict not-taken; first-taken allocates
// strongly-taken (oracle); mispredict resolved at WB. Penalty 3 (U) / 4 (V).
// Key reference: Alpert & Avnon IEEE Micro 1993 p.3 Fig.6 (the BTB structure);
// Intel AP-500 (241799) + Agner Fog (penalties). (M4 gate, PLAN §7.)
//
// Behaviour-preserving extraction (R2): the inline btb_tag/btb_ctr/btb_val/btb_rr
// arrays, the pure-comb btb_lookup() predict, the single btb_update_taken()
// mutating task, and the synchronous reset loop were lifted out of core.sv
// VERBATIM. The two predict ports (U query_pc -> u_predict_taken, V query_pc ->
// v_predict_taken) are COMBINATIONAL off the REGISTERED arrays, so they reflect
// PRE-update state in the same clock a posedge resolve updates them (the
// btb_lookup-vs-next-edge-update read-before-write that func diff cannot see).
// All writes land on posedge through the single funnelled resolve port
// (resolve_valid/resolve_pc/resolve_taken). At most ONE update/clock by
// construction in the core: the U-branch-resolve / V-branch-resolve sites are a
// VERIFIED mutually-exclusive if/else-if (the spine drives resolve_valid =
// u-resolve OR v-resolve, with pc/taken from whichever arm).
//
// Geometry (VERBATIM): set=pc[5:0], tag=pc[31:6]. Predict-taken iff a valid
// matching entry has ctr>=2. On resolve: a hit saturates its 2-bit counter
// toward taken/not-taken; a miss on a TAKEN branch allocates the btb_rr way with
// ctr=3 (strongly-taken, matching plugin/p5model.c:371) and bumps btb_rr; a miss
// on a not-taken branch allocates nothing.

module bpred_btb #(
    parameter int BTB_SETS = 64,   // 256 entries / 4 ways
    parameter int BTB_WAYS = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // Combinational predict ports (timing only): predicted-taken iff a valid
    // matching entry has ctr>=2. Both read the REGISTERED arrays, so they
    // reflect the PRE-update state this clock (the update is applied on posedge
    // below, a true predictor SM, not a combinational peek). The two queries are
    // read-only and independent (U pc, V pc = eip + u.len).
    input  logic [31:0] u_query_pc,
    output logic        u_predict_taken,
    input  logic [31:0] v_query_pc,
    output logic        v_predict_taken,

    // Single funnelled update port: when resolve_valid is high at a posedge,
    // run btb_update_taken on resolve_pc/resolve_taken. Exactly p5model
    // btb_update(). At most ONE update/clock from the core (verified mutually
    // exclusive across the U-branch / V-branch resolve arms).
    input  logic        resolve_valid,
    input  logic [31:0] resolve_pc,
    input  logic        resolve_taken
);

  logic [25:0] btb_tag [BTB_SETS][BTB_WAYS];   // pc/64
  logic [1:0]  btb_ctr [BTB_SETS][BTB_WAYS];   // 2-bit saturating
  logic        btb_val [BTB_SETS][BTB_WAYS];
  logic [1:0]  btb_rr  [BTB_SETS];             // round-robin replacement ptr

  // BTB lookup: predicted-taken iff a valid matching entry has counter>=2.
  // Pure-comb off the registered arrays (does NOT mutate state). VERBATIM from
  // the inline btb_lookup() function, kept as a function so both predict ports
  // share the identical body.
  function automatic logic btb_lookup(input logic [31:0] pc);
    logic [5:0]  set; logic [25:0] tag; logic hit;
    begin
      set = pc[5:0]; tag = pc[31:6]; hit = 1'b0; btb_lookup = 1'b0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin
          hit=1'b1; btb_lookup = (btb_ctr[set][w] >= 2'd2);
        end
    end
  endfunction

  always_comb begin
    u_predict_taken = btb_lookup(u_query_pc);
    v_predict_taken = btb_lookup(v_query_pc);
  end

  // +VEN_BTB_PIPE: register the resolve inputs one clock so the BTB counter
  // UPDATE leaves the eip->icache->decode->issue_arm->btb_ctr critical path (the
  // ~63-level worst path, of which the BTB tail is ~13 levels). The btb_ctr CE
  // then comes from a flop (rv_use), not the combinational issue_arm net. The BTB
  // counter is a STATE side-effect (the predict ports read PRE-update state
  // read-before-write), so applying it one clock later only shifts WHEN the
  // predictor warms — the loose cycle bands (mb_brloop mispredict<2%, mb_brrandom
  // >20%) absorb it. Without the define, the update is combinational as before.
`ifdef VEN_BTB_PIPE
  logic        rv_use; logic [31:0] rpc_use; logic rt_use;
  always_ff @(posedge clk) begin
    if (!rst_n) rv_use <= 1'b0;
    else begin rv_use <= resolve_valid; rpc_use <= resolve_pc; rt_use <= resolve_taken; end
  end
`else
  wire         rv_use  = resolve_valid;
  wire [31:0]  rpc_use = resolve_pc;
  wire         rt_use  = resolve_taken;
`endif

  // BTB update after a branch resolves (mirrors p5model btb_update): a hit
  // saturates its 2-bit counter toward taken/not-taken; a miss on a TAKEN
  // branch allocates a way (round-robin replacement) with a strongly-taken
  // counter; a miss on a not-taken branch allocates nothing. One update per
  // clock from the core. The reset loop becomes the rst_n arm.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s=0;s<BTB_SETS;s++) begin
        btb_rr[s]<=2'd0;
        for (int w=0;w<BTB_WAYS;w++) begin
          btb_val[s][w]<=1'b0; btb_tag[s][w]<=26'd0; btb_ctr[s][w]<=2'd0;
        end
      end
    end else if (rv_use) begin
      logic [5:0]  set; logic [25:0] tag; logic hit; logic [1:0] way;
      set = rpc_use[5:0]; tag = rpc_use[31:6]; hit = 1'b0; way = 2'd0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin hit=1'b1; way=2'(w); end
      if (hit) begin
        if (rt_use && btb_ctr[set][way]!=2'd3) btb_ctr[set][way]<=btb_ctr[set][way]+2'd1;
        if (!rt_use && btb_ctr[set][way]!=2'd0) btb_ctr[set][way]<=btb_ctr[set][way]-2'd1;
      end else if (rt_use) begin
        btb_val[set][btb_rr[set]]<=1'b1;
        btb_tag[set][btb_rr[set]]<=tag;
        // first-taken => STRONGLY taken (ctr=3), matching the p5model oracle
        // (plugin/p5model.c:371 's->ctr[v]=3'). Allocating weakly-taken (2) would
        // diverge after a loop-exit not-taken: 2->1 (predict not-taken) re-warms a
        // mispredict on the next entry, whereas the oracle 3->2 stays predict-taken.
        btb_ctr[set][btb_rr[set]]<=2'd3;     // allocate strongly-taken (oracle)
        btb_rr[set]<=btb_rr[set]+2'd1;
      end
    end
  end

endmodule : bpred_btb
