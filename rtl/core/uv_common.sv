// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/uv_common.sv — shared U/V integer-execution building blocks
//                     (extracted from core.sv, R3; behaviour-preserving).
//
// docs/rtl-refactor-plan.md: the common combinational datapath shared by the
// U-pipe and V-pipe execution units. The ALU result/flags, the shift/rotate
// datapath, and the width/parity helpers are pure functions in
// ventium_alu_pkg (alu_result/flags_next/shrot_result/shrot_cf/wmask); this
// module collects the larger combinational building blocks that are NOT a
// single package call.
//
// Block #1 — BCD / ASCII-adjust datapath (AAA/AAS/DAA/DAS/AAM/AAD). Moved
// VERBATIM from the inline `always_comb` at core.sv (the EXEC datapath routes
// bcd_ax/bcd_flags onto alu_out/flags_out when the op is a BCD adjust). It
// matches QEMU int_helper.c helper_aaa/aas/daa/das/aam/aad EXACTLY. Computes
// the AX result (bcd_ax) + the DEFINED EFLAGS (bcd_flags). Architecturally
// undefined flags (OF always; SF/ZF/PF for AAA/AAS; CF/AF for AAM/AAD) are
// left cleared and are removed from the differential by
// tracefmt.eflags_undefined_mask. AAM base 0 is a #DE this core defers (like
// native DIV-by-zero); the divide is guarded to avoid an X (the corpus never
// executes AAM 0). Outputs default unconditionally (no latch); the `default`
// arm computes AAA and also covers every non-BCD alu_op (harmless dead
// compute — bcd_* are consumed only for BCD ops). Inputs are read-only state
// the spine forwards (gpr[R_EAX] low 16, the imm8, the 5-bit ALU op selector,
// and the live EFLAGS); the netlist is identical to the inline form.

module uv_common
  import ventium_alu_pkg::*;
(
    // ---- BCD / ASCII-adjust datapath -----------------------------------------
    input  logic [15:0] bcd_eax16,   // gpr[R_EAX][15:0] (AL = [7:0], AH = [15:8])
    input  logic [7:0]  bcd_imm8,     // q_imm[7:0] (AAM/AAD base)
    input  logic [4:0]  bcd_alu_op,   // q_alu_op (ALU_AAA..ALU_AAD select)
    input  logic [31:0] bcd_eflags,   // live EFLAGS (carries undefined bits through)
    output logic [15:0] bcd_ax,       // AX result for the adjust
    output logic [31:0] bcd_flags     // defined EFLAGS after the adjust
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
    af0  = bcd_eflags[4];
    cf0  = bcd_eflags[0];
    icar = 1'b0;
    fl   = bcd_eflags & 32'hFFFF_F72A;   // clear CF/PF/AF/ZF/SF/OF
    fl[1]= 1'b1;                         // reserved bit 1 always 1
    nal  = al0; nah = ah0;
    case (bcd_alu_op)
      ALU_AAS: begin
        // QEMU carries SF/ZF/PF/OF THROUGH (only CF/AF change). Must match
        // exactly: the undefined bits persist into later (unmasked) instructions.
        fl = bcd_eflags; fl[1]=1'b1;
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
        fl = bcd_eflags; fl[1]=1'b1;
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

endmodule : uv_common
