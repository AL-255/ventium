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
// dependency (the reads/writes bitmasks the decoder produced already exclude
// ESP/flags). A V-slot load is kept out of the pair (conservative + correct).
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
);

  // pairing checker (mirrors p5model can_pair RULES, not its formula): both
  // simple, V is a V-candidate, U is a U-member, no disp+imm, no prefixes
  // (the fast path only decodes unprefixed forms), no RAW/WAW on GP regs
  // (ESP/flags excepted -> already excluded from reads/writes masks).
  function automatic logic fp_can_pair(input fpd_t u, input fpd_t v);
    begin
      if (!u.simple || !v.simple) return 1'b0;
      if (!u.pairs_first || !v.pairs_second) return 1'b0;
      if (u.disp_imm || v.disp_imm) return 1'b0;
      if ((v.reads & u.writes) != 8'd0) return 1'b0;   // RAW
      if ((v.writes & u.writes) != 8'd0) return 1'b0;  // WAW
      // a load in the V slot is allowed in P5 only as the leading member; keep
      // V-candidate loads out of the pair to stay conservative+correct.
      if (v.is_load) return 1'b0;
      return 1'b1;
    end
  endfunction

  // Combinational pairing decision. Bit-identical to the in-line
  // fp_can_pair(u_d, v_d) call in intcore.sv.
  always_comb pair_ok = fp_can_pair(iu, iv);

endmodule : issue_uv
