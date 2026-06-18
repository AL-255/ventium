// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/v_pipe.sv — P5 V-pipe integer execution datapath
//                  (extracted from core.sv, R3; behaviour-preserving).
//
// docs/rtl-refactor-plan.md / docs/m4-pipeline-spec.md: the V-pipe is the
// RESTRICTED second member of the M4 dual-issue fast path (simple ALU /
// branch). When U leads a pair (issue_uv.pair_ok) the V candidate executes
// here against the OLD register state (the pairing rule guarantees V is
// independent of U), so reading the pre-issue operands is correct. Moved
// VERBATIM from the inline `always_comb` in core.sv; same ventium_alu_pkg pure
// functions, so the netlist is identical.
//
// IF: the spine pre-reads the V operands (dst_val = gpr[v_d.dst],
// src_val = gpr[v_d.src] == reg_read(idx,3'd4,1'b0)) and the live EFLAGS; the
// module returns v_alu / v_flags. The eip-relative V target, the BTB predict,
// and the U->V flag-forwarded branch resolution (v_br_taken_eff) stay in the
// spine / uv_common.

module v_pipe
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
(
    input  fpd_t        v_d,        // V-candidate decode
    input  logic [31:0] v_dst_val,  // gpr[v_d.dst]  (reg_read(v_d.dst,3'd4,1'b0))
    input  logic [31:0] v_src_val,  // gpr[v_d.src]  (reg_read(v_d.src,3'd4,1'b0))
    input  logic [31:0] eflags,     // live architectural EFLAGS
    output logic [31:0] v_alu,      // ALU result (post-commit)
    output logic [31:0] v_flags     // EFLAGS after the ALU op
);

  // second ALU operand (imm / source reg / fixed 1 for INC/DEC) — identical to
  // core.sv fp_bop(), reading the pre-supplied V src operand.
  function automatic logic [31:0] fp_bop(input fpd_t d);
    if (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) fp_bop = 32'd1;
    else if (d.use_imm) fp_bop = d.imm;
    else fp_bop = v_src_val;
  endfunction

  // V datapath (independent of U by the pairing rule, so reading the OLD gpr
  // state is correct for both).
  always_comb begin
    v_alu   = alu_result(v_d.alu_op, v_dst_val, fp_bop(v_d), eflags[0]);
    v_flags = flags_next(v_d.alu_op, v_dst_val, fp_bop(v_d), v_alu, eflags, 3'd4);
  end

endmodule : v_pipe
