// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/uv_common.sv — shared U/V integer-execution building blocks
//                     (extracted from core.sv, R3; behaviour-preserving).
//
// docs/rtl-refactor-plan.md: the common combinational datapath shared by the
// U-pipe and V-pipe execution units. The ALU result/flags, the shift/rotate
// datapath, and the width/parity helpers are pure functions in
// ventium_alu_pkg (alu_result/flags_next/shrot_result/shrot_cf/wmask/parity8);
// this module collects the larger combinational building blocks that are NOT a
// single package call. Both blocks below were moved VERBATIM from core.sv and
// share the live EFLAGS input, so the netlist is identical.
//
// Block #1 — BCD / ASCII-adjust datapath (AAA/AAS/DAA/DAS/AAM/AAD). The EXEC
// datapath routes bcd_ax/bcd_flags onto alu_out/flags_out when the op is a BCD
// adjust. Matches QEMU int_helper.c helper_aaa/aas/daa/das/aam/aad EXACTLY.
// Architecturally-undefined flags (OF always; SF/ZF/PF for AAA/AAS; CF/AF for
// AAM/AAD) are left cleared and are removed from the differential by
// tracefmt.eflags_undefined_mask. The `default` arm computes AAA and also
// covers every non-BCD alu_op (harmless dead compute — bcd_* consumed only for
// BCD ops).
//
// Block #2 — U->V EFLAGS forwarding (the P5 cmp/dec/test + jcc pairing case):
// when the U member writes EFLAGS, the paired V conditional branch must see
// U's RESULT flags, not the stale architectural eflags. Computes U's
// post-commit flags (u_flags_eff, internal) from the u_pipe ALU/shift outputs
// and uses them to resolve a paired conditional V branch (v_br_taken_eff).

module uv_common
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
(
    // ---- shared --------------------------------------------------------------
    input  logic [31:0] eflags,       // live EFLAGS (carries undefined bits through)
    // ---- BCD / ASCII-adjust datapath -----------------------------------------
    input  logic [15:0] bcd_eax16,    // gpr[R_EAX][15:0] (AL = [7:0], AH = [15:8])
    input  logic [7:0]  bcd_imm8,     // q_imm[7:0] (AAM/AAD base)
    input  logic [4:0]  bcd_alu_op,   // q_alu_op (ALU_AAA..ALU_AAD select)
    output logic [15:0] bcd_ax,       // AX result for the adjust
    output logic [31:0] bcd_flags,    // defined EFLAGS after the adjust
    // ---- U->V flag forwarding ------------------------------------------------
    input  fpd_t        u_d,          // U-member decode (wflags/is_shift/shimm)
    input  fpd_t        v_d,          // V-candidate decode (br_cond/cc)
    input  logic [31:0] u_flags,      // u_pipe: U's ALU-result EFLAGS
    input  logic [31:0] u_sh,         // u_pipe: U's shift/rotate result
    input  logic [31:0] u_shm1,       // u_pipe: U operand shifted by (count-1)
    input  logic        u_shcf,       // u_pipe: U's shift/rotate carry-out
    output logic        v_br_taken_eff // V branch taken using U's forwarded flags
);

  // ===========================================================================
  // BCD / ASCII-adjust datapath (verbatim from core.sv)
  // ===========================================================================
  always_comb begin
    logic [7:0]  al0, ah0, imm8, nal, nah;
    logic        af0, cf0, icar;
    logic [31:0] fl;
    al0  = bcd_eax16[7:0];
    ah0  = bcd_eax16[15:8];
    imm8 = bcd_imm8;
    af0  = eflags[4];
    cf0  = eflags[0];
    icar = 1'b0;
    fl   = eflags & 32'hFFFF_F72A;   // clear CF/PF/AF/ZF/SF/OF
    fl[1]= 1'b1;                     // reserved bit 1 always 1
    nal  = al0; nah = ah0;
    case (bcd_alu_op)
      ALU_AAS: begin
        // QEMU carries SF/ZF/PF/OF THROUGH (only CF/AF change). Must match
        // exactly: the undefined bits persist into later (unmasked) instructions.
        fl = eflags; fl[1]=1'b1;
        icar = (al0 < 8'd6);
        if ((al0[3:0] > 4'd9) || af0) begin
          nal = (al0 - 8'd6) & 8'h0F; nah = ah0 - 8'd1 - {7'd0,icar};
          fl[0]=1'b1; fl[4]=1'b1;
        end else begin nal = al0 & 8'h0F; fl[0]=1'b0; fl[4]=1'b0; end
      end
      ALU_DAA: begin
        if ((al0[3:0] > 4'd9) || af0) begin nal = al0 + 8'd6;  fl[4]=1'b1; end
        if ((al0 > 8'h99)     || cf0) begin nal = nal + 8'h60; fl[0]=1'b1; end
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];          // ZF/PF/SF
      end
      ALU_DAS: begin
        if ((al0[3:0] > 4'd9) || af0) begin
          fl[4]=1'b1; if ((al0 < 8'd6) || cf0) fl[0]=1'b1; nal = al0 - 8'd6;
        end
        if ((al0 > 8'h99) || cf0) begin nal = nal - 8'h60; fl[0]=1'b1; end
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];
      end
      ALU_AAM: begin
        nah = (imm8==8'd0) ? 8'd0 : (al0 / imm8);   // AH = AL/base
        nal = (imm8==8'd0) ? 8'd0 : (al0 % imm8);   // AL = AL%base
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];          // CF/OF/AF undef
      end
      ALU_AAD: begin
        nal = (ah0 * imm8) + al0; nah = 8'd0;       // AL = AH*base+AL; AH=0
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];
      end
      default: begin // ALU_AAA (and every non-BCD op: harmless dead compute)
        // QEMU carries SF/ZF/PF/OF THROUGH (only CF/AF change) — match exactly.
        fl = eflags; fl[1]=1'b1;
        icar = (al0 > 8'hF9);
        if ((al0[3:0] > 4'd9) || af0) begin
          nal = (al0 + 8'd6) & 8'h0F; nah = ah0 + 8'd1 + {7'd0,icar};
          fl[0]=1'b1; fl[4]=1'b1;                   // CF=AF=1
        end else begin nal = al0 & 8'h0F; fl[0]=1'b0; fl[4]=1'b0; end  // CF=AF=0
      end
    endcase
    bcd_ax    = {nah, nal};
    bcd_flags = fl;
  end

  // ===========================================================================
  // U->V EFLAGS forwarding (verbatim from core.sv)
  // ===========================================================================
  always_comb begin
    logic [31:0] u_flags_eff;
    u_flags_eff = u_d.wflags ? u_flags : eflags;
    if (u_d.is_shift) begin
      if (u_d.shimm!=5'd0) begin
        // shift (SHL/SHR/SAL/SAR group) result flags, for a paired following jcc.
        u_flags_eff = eflags & 32'hFFFF_F72A;
        u_flags_eff[0]=u_shcf; u_flags_eff[2]=parity8(u_sh[7:0]); u_flags_eff[4]=1'b0;
        u_flags_eff[6]=(u_sh==32'd0); u_flags_eff[7]=u_sh[31];
        u_flags_eff[11]=u_shm1[31]^u_sh[31]; u_flags_eff[1]=1'b1;
      end else u_flags_eff = eflags;   // count 0 => no flag change
    end
    // v_br_cc(v_d) == v_d.cc (the raw Jcc condition carried in the decode).
    v_br_taken_eff = v_d.br_cond ? cond_true(v_d.cc, u_flags_eff) : 1'b1;
  end

endmodule : uv_common
