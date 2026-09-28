`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/issue_uv.sv — U/V dual-issue pairing checker (AP-500 pairing classes).
//
// Extracted VERBATIM from intcore.sv (R1 modularization phase 3,
// docs/rtl-refactor-plan.md). This is the P5 pairing checker: given the U
// instruction's decode and the V candidate's decode (both decoded-uop structs),
// it decides whether the two may issue together in the same clock (pair_ok).
// It mirrors the p5model can_pair RULES (AP-500/Agner-Fog P5 pairing classes,
// docs/ap500-pairing-table.md): both members simple, U a U-member (pairs_first),
// V a V-candidate (pairs_second), no disp+imm, and no RAW/WAW GP-register
// dependency.  ESP RAW dependencies are included because this implementation
// has no U-to-V stack-pointer bypass; an ESP-only WAW remains pairable. A
// V-slot load is kept out of the pair (conservative + correct).
//
// IF (docs/rtl-refactor-plan.md §6 issue_uv.sv): two decoded uops (+ the
// reg-write state, which is carried inside the structs' reads/writes masks) ->
// pair_ok. The V-pipe assignment is implicit: the V candidate fills the V slot
// exactly when pair_ok holds. fp_can_pair below is moved BIT-FOR-BIT.

module issue_uv
  import ventium_decode_pkg::*;
(
    input  fpd_t iu,       // U-member decode
    input  fpd_t iv,       // V-candidate decode (the instruction right after U)
    output logic pair_ok   // 1 => U and V may issue together this clock
`ifdef VEN_P54_DUAL_LOAD_PAIR
  , output logic pair_mem_ok // two independently owned read operands
`endif
`ifdef VEN_P54_REGMEM_PRIME
  , output logic pair_regmem_ok // independent register U + checked read V
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
  , output logic pair_store_ok // two independent full-dword register stores
`endif
`ifdef VEN_P54_LOAD_STORE_PAIR
  , output logic pair_load_store_ok // U MOV load, V independent MOV store
`endif
`ifdef VEN_PERF_PROFILE
    // Simulation-only first-rejection attribution.  It is deliberately an
    // output of the same leaf that decides pair_ok, rather than a second copy
    // of the P5 table in the profiler.  No production build enables it.
  , output logic [2:0] pair_reason
`endif
);

  localparam logic [7:0] ESP_MASK = 8'h10;
`ifdef VEN_PERF_PROFILE
  localparam logic [2:0] PR_OK       = 3'd0;
  localparam logic [2:0] PR_SIMPLE   = 3'd1;
  localparam logic [2:0] PR_CLASS    = 3'd2;
  localparam logic [2:0] PR_DISPIMM  = 3'd3;
  localparam logic [2:0] PR_RAW      = 3'd4;
  localparam logic [2:0] PR_WAW      = 3'd5;
  localparam logic [2:0] PR_VMEM     = 3'd6;
`endif

  // pairing checker (mirrors p5model can_pair RULES, not its formula): both
  // simple, V is a V-candidate, U is a U-member, no disp+imm, no prefixes
  // (the fast path only decodes unprefixed forms), no RAW/WAW on GP regs
  // (ESP RAW included; only an ESP-only WAW is deliberately retained).
  function automatic logic fp_can_pair(input fpd_t u, input fpd_t v,
                                        input logic allow_v_mem);
    begin
      if (!u.simple || !v.simple) return 1'b0;
      if (!u.pairs_first || !v.pairs_second) return 1'b0;
      if (u.disp_imm || v.disp_imm) return 1'b0;
      // RAW serializes unless the optional checked-load bypass supplies the
      // V ALU operand. ESP has no general arithmetic/stack bypass. Existing
      // write/write pairing is safe when V does not consume U's result.
      if (((v.reads & u.writes) != 8'd0) && !fp_load_use_forwardable(u, v)) return 1'b0;
      if ((v.writes & (u.writes & ~ESP_MASK)) != 8'd0)
        return 1'b0;                                    // WAW, except ESP-only
      // The one checked data-read port belongs to U.  A V memory form would
      // otherwise consume stale mem_rdata without issuing a request, so keep all
      // V memory operands out of the pair (MOV loads and read-only ALU operands).
      if (v.is_mem && !allow_v_mem) return 1'b0;
      return 1'b1;
    end
  endfunction

  // Combinational pairing decision. Bit-identical to the in-line
  // fp_can_pair(u_d, v_d) call in intcore.sv.
  always_comb pair_ok = fp_can_pair(iu, iv, 1'b0);
`ifdef VEN_P54_DUAL_LOAD_PAIR
  // Never use the checked-load-to-register bypass to admit a dependent V
  // address or payload. This path has two independent D2 addresses and may
  // retire only after both separately owned resident responses are present.
  always_comb pair_mem_ok = fp_can_pair(iu, iv, 1'b1) &&
      iu.is_mem && !iu.is_store && !iu.is_stack &&
      ((iu.is_load && iu.wreg)
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
       // Both pipes have a separately owned read. The older U may itself be
       // a read-only ALU reg,[mem] or CMP reg,[mem]; its result/flags commit
       // before V's result/flags on the shared two-clock EX schedule.
       || (!iu.is_load && !iu.mem_lhs && iu.wflags)
`endif
       ) &&
      iv.is_mem && !iv.is_store && !iv.is_stack &&
      ((iv.is_load && iv.wreg)
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
       // P54 ALU reg,[mem] occupies two EX clocks; the registered L1 hit
       // supplies the second clock.  Exclude memory-destination forms (three
       // clocks, and potentially a write), ADC/SBB (not V-pairable), and any
       // form without the flags/result contract handled by the V ALU.
       || (!iv.is_load && !iv.mem_lhs && iv.wflags)
`endif
       ) &&
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
      // A resident byte MOV load needs only its addressed byte bank. Its
      // separately tagged V response is width-merged at ordered commit.
      // Byte ALU-memory operands keep the older dword-only EX contract.
      (!iu.w8 || iu.is_load) && (!iv.w8 || iv.is_load) &&
`else
      !iu.w8 && !iv.w8 &&
`endif
      !iu.w16 && !iv.w16 &&
      !fp_is_ext_load(iu) && !fp_is_ext_load(iv) &&
      ((iv.reads & iu.writes) == 8'd0) &&
      ((iv.addr_mask & iu.writes) == 8'd0);
`endif
`ifdef VEN_P54_REGMEM_PRIME
  // A register U may pair with a V read only when a separately translated,
  // owner-tagged resident response has already been captured. This predicate
  // checks instruction classes and dependencies; core.sv proves that response.
  // The V ALU read uses the same checked D2 response as the existing dual-read
  // pair; the V datapath consumes it only on the ordered commit edge.
  always_comb pair_regmem_ok = fp_can_pair(iu, iv, 1'b1) &&
      !iu.is_mem && !iu.is_store && !iu.is_stack && !iu.is_fp &&
      !iu.is_branch && !iu.is_shift && !iu.w16 &&
      iv.is_mem && !iv.is_store && !iv.is_stack && !iv.is_fp &&
      ((iv.is_load && iv.wreg)
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
       || (!iv.is_load && !iv.mem_lhs && iv.wflags)
`endif
       ) && !iv.w8 && !iv.w16 &&
      ((iv.addr_mask & iu.writes) == 8'd0);
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
  // Keep store admission out of the ordinary pair_ok path until both checked
  // physical requests and both backing slots are owned. Only plain full-dword
  // register stores fit the first L1 pair lane: no RMW, byte/word, implicit
  // stack, FP, flag, or immediate side effect may retire through it.
  always_comb pair_store_ok = fp_can_pair(iu, iv, 1'b1) &&
      iu.is_mem && iu.is_store && !iu.is_load && !iu.is_stack && !iu.is_fp &&
      iv.is_mem && iv.is_store && !iv.is_load && !iv.is_stack && !iv.is_fp &&
      !iu.mem_lhs && !iv.mem_lhs && !iu.wreg && !iv.wreg &&
      !iu.wflags && !iv.wflags && !iu.use_imm && !iv.use_imm &&
      !iu.w8 && !iv.w8 && !iu.w16 && !iv.w16;
`endif
`ifdef VEN_P54_LOAD_STORE_PAIR
  // U owns the ordinary checked, registered read response.  V may post one
  // independent aligned store at U's consume edge; neither operand may read
  // a register written by U, and there is no speculative V memory access.
  always_comb pair_load_store_ok = fp_can_pair(iu, iv, 1'b1) &&
      iu.is_mem && iu.is_load && !iu.is_store && !iu.is_stack && !iu.is_fp &&
      iu.wreg && !iu.wflags && !iu.w8 && !iu.w16 &&
      iv.is_mem && iv.is_store && !iv.is_load && !iv.is_stack && !iv.is_fp &&
      !iv.mem_lhs && !iv.wreg && !iv.wflags && !iv.use_imm &&
      !iv.w8 && !iv.w16 &&
      ((iv.reads & iu.writes) == 8'd0) &&
      ((iv.addr_mask & iu.writes) == 8'd0);
`endif

`ifdef VEN_PERF_PROFILE
  // Preserve fp_can_pair as the only functional predicate above.  This
  // priority-matched classification has diagnostic fanout only, and the
  // profiler checks that it is non-OK whenever pair_ok is low.
  always_comb begin
    pair_reason = PR_OK;
    if (!iu.simple || !iv.simple) pair_reason = PR_SIMPLE;
    else if (!iu.pairs_first || !iv.pairs_second) pair_reason = PR_CLASS;
    else if (iu.disp_imm || iv.disp_imm) pair_reason = PR_DISPIMM;
    else if (((iv.reads & iu.writes) != 8'd0) && !fp_load_use_forwardable(iu, iv)) pair_reason = PR_RAW;
    else if ((iv.writes & (iu.writes & ~ESP_MASK)) != 8'd0) pair_reason = PR_WAW;
    else if (iv.is_mem) pair_reason = PR_VMEM;
  end
`endif

endmodule : issue_uv
