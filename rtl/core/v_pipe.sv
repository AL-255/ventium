`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
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
  logic [31:0] v_a_w, v_b_w;   // task #56 layer 11: width-masked ALU operands
  always_comb begin
    // task #56 layer 11: the SLOW path masks BOTH ALU operands to the operand width
    //   core.sv:2028  a_op = reg_read(q_dst_reg, q_w, ...)
    //   core.sv:2029  b_op = wmask(q_imm, q_w)
    // The fast path fed FULL 32-bit operands to alu_result, which takes no width argument at all.
    // A 16-bit ADD/SUB therefore carried past bit 15 into the upper half, and flags_next (fixed in
    // step H) then derived CF/OF from an already-contaminated result. Mask with the SAME wmask
    // helper the slow path uses (ventium_alu_pkg:47). At w16=0 wmask(v,3'd4) is the identity, so
    // this is inert in user mode.
    v_a_w  = wmask(v_dst_val, fp_operand_width(v_d));
    v_b_w  = wmask(fp_bop(v_d), fp_operand_width(v_d));
    v_alu   = alu_result(v_d.alu_op, v_a_w, v_b_w, eflags[0]);
    // task #56 step H: the width argument was HARDCODED 3'd4 (32-bit) while the slow
    // path passes q_w (core.sv:2034). A 16-bit op therefore set ZF/SF/CF/OF from the
    // full 32-bit result -> wrong conditional branches -> guest divergence (UPDATE 279).
    // flags_next already handles width; it was simply never told.
    v_flags = flags_next(v_d.alu_op, v_a_w, v_b_w, v_alu, eflags, fp_operand_width(v_d));
  end

endmodule : v_pipe
