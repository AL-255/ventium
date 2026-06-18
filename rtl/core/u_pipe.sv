// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/u_pipe.sv — P5 U-pipe integer execution datapath
//                  (extracted from core.sv, R3; behaviour-preserving).
//
// docs/rtl-refactor-plan.md / docs/m4-pipeline-spec.md: the U-pipe is the
// full-featured ALU member of the M4 dual-issue fast path. Given the U
// instruction's decode (fpd_t) and its register operands, it computes the
// post-commit ALU result + EFLAGS and the shift/rotate datapath outputs the
// spine consumes in S_PIPE. Moved VERBATIM from the inline `always_comb` in
// core.sv; the arithmetic helpers (alu_result/flags_next/shrot_result/
// shrot_cf) are the SAME pure functions in ventium_alu_pkg, so the netlist is
// identical.
//
// IF: the spine pre-reads the U operands (dst_val = gpr[u_d.dst],
// src_val = gpr[u_d.src]) — these are exactly reg_read(idx,3'd4,1'b0) (the
// fast path always reads full 32-bit dwords) — and the live EFLAGS; the module
// returns u_alu / u_flags / u_sh / u_shm1 / u_shcf. The branch target
// (eip-relative) and the BTB predict stay in the spine.

module u_pipe
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
(
    input  fpd_t        u_d,        // U-member decode
    input  logic [31:0] u_dst_val,  // gpr[u_d.dst]  (reg_read(u_d.dst,3'd4,1'b0))
    input  logic [31:0] u_src_val,  // gpr[u_d.src]  (reg_read(u_d.src,3'd4,1'b0))
    input  logic [31:0] eflags,     // live architectural EFLAGS
    output logic [31:0] u_alu,      // ALU result (post-commit)
    output logic [31:0] u_flags,    // EFLAGS after the ALU op
    output logic [31:0] u_sh,       // shift/rotate result
    output logic [31:0] u_shm1,     // operand shifted by (count-1) (CC_SRC)
    output logic        u_shcf      // shift/rotate carry-out
);

  // second ALU operand for a fast-path ALU/mov insn: imm, or the source reg, or
  // a fixed 1 for INC/DEC (matching the slow path's b_op selection). Identical
  // to core.sv fp_bop(), reading the pre-supplied src operand.
  function automatic logic [31:0] fp_bop(input fpd_t d);
    if (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) fp_bop = 32'd1;
    else if (d.use_imm) fp_bop = d.imm;
    else fp_bop = u_src_val;
  endfunction

  // U datapath (reuse the shared helpers; results are bit-identical to slow).
  // INC/DEC use a fixed second operand of 1 (matching the slow path's b_op).
  always_comb begin
    u_alu   = alu_result(u_d.alu_op, u_dst_val, fp_bop(u_d), eflags[0]);
    u_flags = flags_next(u_d.alu_op, u_dst_val, fp_bop(u_d), u_alu, eflags, 3'd4);
    u_sh    = shrot_result(u_d.shrot, u_dst_val, {1'b0,u_d.shimm}, eflags[0], 3'd4);
    u_shm1  = (u_d.shimm==5'd0) ? u_dst_val
              : shrot_result(u_d.shrot, u_dst_val,
                             {1'b0,u_d.shimm}-6'd1, eflags[0], 3'd4);
    u_shcf  = shrot_cf(u_d.shrot, u_dst_val, {1'b0,u_d.shimm}, eflags[0], 3'd4);
  end

endmodule : u_pipe
