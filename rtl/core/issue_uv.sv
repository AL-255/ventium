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
  function automatic logic fp_can_pair(input fpd_t u, input fpd_t v);
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
      if (v.is_mem) return 1'b0;
      return 1'b1;
    end
  endfunction

  // Combinational pairing decision. Bit-identical to the in-line
  // fp_can_pair(u_d, v_d) call in intcore.sv.
  always_comb pair_ok = fp_can_pair(iu, iv);

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
