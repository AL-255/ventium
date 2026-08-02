`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/decode_stages.sv — the Ventium SLOW-PATH instruction decoder
//                         (extracted from core.sv, R3; behaviour-preserving).
//
// This is the big combinational prefix + length + operand decode block that the
// multi-cycle FSM in core.sv drives in S_DECODE. It was lifted VERBATIM out of
// core.sv (the prefix machine, the eff_opsize/eff_addr derivation, the sreg_idx
// helper, and the ~1400-line main decoder always_comb) into this true module so
// core.sv keeps only the pipeline spine + the q_* decode latch + the FSM.
//
// PURE REFACTOR: the moved logic is byte-for-byte the original — every d_*
// output it produced is exposed as a same-named module output port, every
// architectural input it read (ibuf/gpr/eflags/mode bits) is a module input
// port, and the ModR/M+SIB + prefix scratch signals are now module-internal.
// The decode is netlist-identical to the in-line block it replaced (verified
// byte-for-byte vs the QEMU goldens by the refactor gate).
//
// d_sysop's enum type `sysop_e` is declared at compilation-unit ($unit) scope at
// the TOP of core.sv (it was an in-module typedef there before R3; promoted to
// $unit, which precedes core.sv in compile order, so BOTH this module's d_sysop
// output port and core.sv's `sysop_e d_sysop`/`q_sysop` wires + the svh
// q_sysop==SYS_* compares resolve to the one SAME type). Enumerators unchanged.

module decode_stages
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
(
    // ---- inputs: architectural + fetch state the decoder READS -------------
    input  logic [7:0]  ibuf [16],          // the 16-byte fetch window at EIP
    input  logic [31:0] gpr  [NUM_GPR],     // GP register file (EA base/index)
    input  logic [31:0] eflags,             // EFLAGS (Jcc condition eval)
    input  logic        sys_mode,           // system-mode core
    input  logic        def16,              // 16-bit default operand/address size
    input  logic        seg_real,           // real-mode/V86 segment base addressing
    input  logic        smm_active,         // in SMM (gates RSM)
    input  logic        paging_on,          // CR0.PG && CR0.PE (sys mode)
    input  logic        cosim_en,           // Win95 co-sim port-I/O bus enable
    input  logic        soc_en,             // external-interrupt / SoC firmware enable

    // ---- outputs: the leaked prefix/ModR/M intermediates the spine ALSO reads
    output logic [2:0]  modrm_reg,          // ModR/M.reg (read by spine/FSM)
    output logic [1:0]  pfx_rep,            // 0 none, 2 F2, 3 F3
    output logic        pfx_seg,            // a segment-override prefix is present
    output logic        pfx_lock,           // a 0xF0 LOCK prefix is present
    output logic        pfx_addr,           // a 0x67 address-size prefix is present
    output logic        eff_opsize,         // effective operand-size (prefix ^ def16)
    output logic        eff_addr,           // effective address-size  (prefix ^ def16)

    // ---- outputs: the decoded fields (the d_* the q_* latch consumes) ------
    output logic [3:0]  d_len,
    output logic        d_halt,
    // REVIEW_aug2 H-06: INVD (0F 08) / WBINVD (0F 09). They retire as NOPs, so
    // d_is_nop is all the rest of the machine needs -- but that leaves NO predicate
    // for the centralized CPL0 check to reject them at CPL3. Flagged explicitly.
    output logic        d_cacheinv,
    // REVIEW1_Aug2 C-10: expose the LOCK prefix so the core can request a locked
    // bus transaction. pfx_lock was consumed only by the #UD/errata checks.
    output logic        d_lock,
    output logic        d_int80,
    output logic        d_unknown,
    output logic        d_int,
    output logic [7:0]  d_int_vec,
    output logic        d_int_imm,
    output logic        d_int_cond_of,
    output logic        d_iret,
    output logic        d_ud2,
    output logic        d_rsm,
    output logic        d_f00f,
    output logic        d_is_branch,
    output logic        d_branch_taken,
    output logic [31:0] d_rel,
    output logic [4:0]  d_alu_op,
    output logic        d_writes_reg,
    output logic        d_writes_flags,
    output logic        d_mem_read,
    output logic        d_mem_write,
    output logic        d_mem_dst,
    output logic [2:0]  d_dst_reg,
    output logic [2:0]  d_src_reg,
    output logic [31:0] d_imm,
    output logic        d_use_imm,
    output logic        d_is_push,
    output logic        d_is_pop,
    output logic        d_is_lea,
    output logic        d_is_mov,
    output logic        d_is_nop,
    output logic [31:0] d_ea,
    output logic [2:0]  d_w,
    output logic        d_dst_high8,
    output logic        d_src_high8,
    output kind_e       d_kind,
    output logic [2:0]  d_shrot,
    output logic        d_shift_cl,
    output logic        d_shift_one,
    output logic [4:0]  d_shift_imm,
    output logic        d_shrd,
    output logic [2:0]  d_md,
    output logic        d_imul_3op,
    output logic [31:0] d_imul_imm,
    output logic        d_ext_signed,
    output logic [2:0]  d_ext_srcw,
    output logic [3:0]  d_cc,
    output logic        d_bit_imm,
    output logic [2:0]  d_bit_op,
    output logic        d_conv_cdq,
    output smk_e        d_sm,
    output st_e         d_st,
    output logic        d_str_loadsi,
    output logic        d_str_storedi,
    output logic        d_str_scandi,
    output ctk_e        d_ct,
    output logic [15:0] d_ret_imm,
    output logic        d_cld,
    output logic        d_std,
    output logic        d_clc,
    output logic        d_stc,
    output logic        d_cmc,
    output logic        d_cli,
    output logic        d_sti,
    output logic        d_cnt16,
    output logic        d_br16,
    output logic        d_io,
    output logic        d_io_write,
    output logic        d_io_imm,
    output logic [7:0]  d_io_port_imm,
    output logic [2:0]  d_io_w,
    output logic [2:0]  d_seg,
    output sysop_e      d_sysop,
    output logic [2:0]  d_sys_sreg,
    output logic [2:0]  d_sys_creg,
    output logic        d_clts,          // REVIEW2 H-23: CLTS (0F 06)
    output logic [31:0] d_ljmp_off,
    output logic [15:0] d_ljmp_sel,
    output logic        d_seg_load,
    output logic [2:0]  d_lseg,
    output logic        d_push_sreg,
    output logic        d_pop_sreg,
    output logic        d_seg_load_lo,
    output logic        d_store_sreg,
    output logic        d_xlat,
    output logic        d_callf_mem,
    output logic        d_jmpf_mem,
    output logic        d_pfx_seg_en,
    output logic [2:0]  d_pfx_seg_idx,
    output fxop_e       d_fxop,
    output logic        d_is_x87,
    output logic        d_f_mem_read,
    output logic        d_f_mem_write,
    output logic [2:0]  d_f_msize,
    output logic [3:0]  d_f_mbytes,
    output logic        d_f_pop,
    output logic        d_f_pop2,
    output logic [2:0]  d_f_sti,
    output logic [2:0]  d_f_aluop,
    output logic [2:0]  d_f_const
);

  // SEG_KEYS index constants (cs ss ds es fs gs) — used by the prefix machine
  // and sreg_idx() below (copied from core.sv line 523).
  localparam int SG_CS = 0, SG_SS = 1, SG_DS = 2, SG_ES = 3, SG_FS = 4, SG_GS = 5;

  // ===========================================================================
  // ModR/M + SIB helpers (module-internal scratch; moved from core.sv)
  // ===========================================================================
  logic [3:0]  m_idx;
  logic [1:0]  modrm_mod;
  logic [2:0]  modrm_rm;
  logic        has_sib;
  logic [1:0]  sib_scale;
  logic [2:0]  sib_index;
  logic [2:0]  sib_base;
  logic [7:0]  mrm, sibb;

  // mfl() (ModR/M field length) lives in ventium_decode_pkg.

  // ===========================================================================
  // Prefix machine (module-internal scratch; moved from core.sv)
  // ===========================================================================
  logic [3:0] pfx_len;
  logic       pfx_opsize;
  logic [7:0] op0, op1;
  logic       two_byte;

  // is_prefix() lives in ventium_decode_pkg.

  // ===========================================================================
  // Prefix machine (moved VERBATIM from core.sv)
  // ===========================================================================
  always_comb begin
    pfx_len=4'd0; pfx_opsize=1'b0; pfx_addr=1'b0; pfx_seg=1'b0; pfx_lock=1'b0; pfx_rep=2'd0;
    d_pfx_seg_en=1'b0; d_pfx_seg_idx=3'd0;
    for (int i=0;i<4;i++) begin
      if (is_prefix(ibuf[pfx_len])) begin
        unique case (ibuf[pfx_len])
          8'h66: pfx_opsize=1'b1;
          8'h67: pfx_addr=1'b1;
          8'hF3: pfx_rep=2'd3;
          8'hF2: pfx_rep=2'd2;
          8'hF0: pfx_lock=1'b1;
          // segment-override prefixes (M2S.1): record which segment they pick.
          8'h2E: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_CS); end
          8'h36: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_SS); end
          8'h3E: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_DS); end
          8'h26: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_ES); end
          8'h64: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_FS); end
          8'h65: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_GS); end
          default: pfx_seg=1'b1;
        endcase
        pfx_len = pfx_len + 4'd1;
      end
    end
    op0=ibuf[pfx_len];
    two_byte=(op0==8'h0F);
    op1=ibuf[pfx_len+4'd1];
  end

  // M2S.1: EFFECTIVE operand/address size (moved VERBATIM from core.sv).
  assign eff_opsize = pfx_opsize ^ def16;
  assign eff_addr   = pfx_addr   ^ def16;

  // x86 segment-register field (ModR/M.reg for MOV Sreg) -> our SG_ index
  // (moved VERBATIM from core.sv; uses the SG_* localparams above).
  function automatic logic [2:0] sreg_idx(input logic [2:0] e);
    unique case (e)
      3'd0: sreg_idx = 3'(SG_ES);
      3'd1: sreg_idx = 3'(SG_CS);
      3'd2: sreg_idx = 3'(SG_SS);
      3'd3: sreg_idx = 3'(SG_DS);
      3'd4: sreg_idx = 3'(SG_FS);
      default: sreg_idx = 3'(SG_GS);
    endcase
  endfunction

  // ===========================================================================
  // Combinational decoder (moved VERBATIM from core.sv)
  // ===========================================================================
  always_comb begin
    d_len=4'd1; d_halt=1'b0; d_cacheinv=1'b0; d_lock=1'b0; d_int80=1'b0; d_unknown=1'b0; d_f00f=1'b0; d_is_branch=1'b0; d_branch_taken=1'b0;
    d_rel=32'd0; d_alu_op=ALU_ADD; d_writes_reg=1'b0; d_writes_flags=1'b0;
    d_mem_read=1'b0; d_mem_write=1'b0; d_mem_dst=1'b0; d_dst_reg=3'd0; d_src_reg=3'd0;
    d_imm=32'd0; d_use_imm=1'b0; d_is_push=1'b0; d_is_pop=1'b0; d_is_lea=1'b0;
    d_is_mov=1'b0; d_is_nop=1'b0; d_ea=32'd0; d_w=3'd4; d_dst_high8=1'b0; d_src_high8=1'b0;
    d_kind=K_ALU; d_shrot=3'd0; d_shift_cl=1'b0; d_shift_one=1'b0; d_shift_imm=5'd0;
    d_shrd=1'b0; d_md=3'd0; d_imul_3op=1'b0; d_imul_imm=32'd0; d_ext_signed=1'b0;
    d_ext_srcw=3'd1; d_cc=4'd0; d_bit_imm=1'b0; d_bit_op=3'd4; d_conv_cdq=1'b0;
    d_sm=SM_PUSHA; d_st=ST_MOVS; d_str_loadsi=1'b0; d_str_storedi=1'b0; d_str_scandi=1'b0;
    d_ct=CT_CALLREL; d_ret_imm=16'd0; d_cld=1'b0; d_std=1'b0;
    d_clc=1'b0; d_stc=1'b0; d_cmc=1'b0; d_cli=1'b0; d_sti=1'b0; d_cnt16=eff_addr;
    d_br16=1'b0;
    d_io=1'b0; d_io_write=1'b0; d_io_imm=1'b0; d_io_port_imm=8'd0; d_io_w=3'd1;
    d_fxop=FX_NONE; d_is_x87=1'b0; d_f_mem_read=1'b0; d_f_mem_write=1'b0;
    d_f_msize=3'd0; d_f_mbytes=4'd0; d_f_pop=1'b0; d_f_pop2=1'b0; d_f_sti=3'd0;
    d_f_aluop=3'd0; d_f_const=3'd0;
    // M2S.1 system-decode defaults. d_seg defaults to DS for data accesses (stack
    // ops override to SS in their handlers below); a segment-override prefix wins.
    d_sysop=SYS_NONE;
    d_clts = 1'b0; d_sys_sreg=3'd0; d_sys_creg=3'd0;
    d_ljmp_off=32'd0; d_ljmp_sel=16'd0;
    d_seg_load=1'b0; d_lseg=3'd0;
    d_push_sreg=1'b0; d_pop_sreg=1'b0; d_seg_load_lo=1'b0; d_store_sreg=1'b0;
    d_xlat=1'b0;
    d_callf_mem=1'b0; d_jmpf_mem=1'b0;
    d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
    // M2S.3 interrupt/return decode defaults.
    d_int=1'b0; d_int_vec=8'd0; d_int_imm=1'b0; d_int_cond_of=1'b0; d_iret=1'b0; d_ud2=1'b0;
    d_rsm=1'b0;

    m_idx     = pfx_len + (two_byte ? 4'd2 : 4'd1);
    mrm       = ibuf[m_idx];
    sibb      = ibuf[m_idx+4'd1];
    modrm_mod = mrm[7:6];
    modrm_reg = mrm[5:3];
    modrm_rm  = mrm[2:0];
    has_sib   = (modrm_mod!=2'b11) && (modrm_rm==3'b100);
    sib_scale = sibb[7:6];
    sib_index = sibb[5:3];
    sib_base  = sibb[2:0];

    begin
      logic [31:0] base_val, index_val, disp_val;
      logic [3:0]  disp_idx;
      logic        no_base, no_index;
      no_base=1'b0; no_index=1'b0; base_val=32'd0; index_val=32'd0; disp_val=32'd0;
      disp_idx=m_idx+4'd1;
      if (has_sib) begin
        disp_idx=m_idx+4'd2;
        if (sib_base==3'b101 && modrm_mod==2'b00) no_base=1'b1;
        else base_val=gpr[sib_base];
        if (sib_index==3'b100) no_index=1'b1;
        else index_val=gpr[sib_index]<<sib_scale;
      end else begin
        if (modrm_mod==2'b00 && modrm_rm==3'b101) no_base=1'b1;
        else base_val=gpr[modrm_rm];
      end
      if (modrm_mod==2'b01) disp_val={{24{ibuf[disp_idx][7]}}, ibuf[disp_idx]};
      else if (modrm_mod==2'b10 ||
               (modrm_mod==2'b00 && !has_sib && modrm_rm==3'b101) ||
               (modrm_mod==2'b00 && has_sib && sib_base==3'b101))
        disp_val={ibuf[disp_idx+3],ibuf[disp_idx+2],ibuf[disp_idx+1],ibuf[disp_idx]};
      d_ea=(no_base?32'd0:base_val)+(no_index?32'd0:index_val)+disp_val;
      // F3 — 32-bit EBP/ESP-based forms default to SS (SDM Table 2-2/2-3): SIB
      // base=ESP (any mod), SIB base=EBP with mod!=00 (mod==00 is disp32 -> DS),
      // and non-SIB [EBP+disp] (mod 01/10). A segment-override prefix wins. This
      // was MISSING: `mov ds,[esp+8]` (SeaBIOS's extra-stack IRQ trampoline,
      // a32 SIB) read DS:[esp+8] instead of SS:[esp+8] in real mode, loaded a
      // garbage segment, and saved the IRQ context over the freshly-loaded
      // FreeDOS kernel image (the F3 depack 43-byte slip). Invisible in every
      // flat gate (all segment bases equal), so make verify stays byte-identical.
      if (!d_pfx_seg_en && !eff_addr &&
          ((has_sib && (sib_base==3'b100 ||
                        (sib_base==3'b101 && modrm_mod!=2'b00))) ||
           (!has_sib && modrm_rm==3'b101 && modrm_mod!=2'b00)))
        d_seg = 3'(SG_SS);
    end

    // F3 — 16-bit ADDRESSING (eff_addr==1, i.e. real mode w/o a 0x67 prefix). The
    // 32-bit EA block above used the 32-bit ModR/M model (base_val=gpr[rm], SIB),
    // which is WRONG for 16-bit forms — so recompute d_ea here from the 16-bit
    // base/index table (no SIB in 16-bit addressing). Until now only the direct
    // `[disp16]` form was handled; every register form ([bx],[si],[bp+disp],[bx+si]..)
    // silently used the 32-bit gpr[rm] EA, which broke hand-written 16-bit real-mode
    // asm (gcc/SeaBIOS use a 0x67 a32 prefix so eff_addr=0 and were unaffected; the
    // FreeDOS MBR's `test byte [bx],0x80` partition scan hit it). mfl_e(eff_addr,..)
    // already gives the right LENGTH, so only d_ea (and the BP->SS default) need work.
    //   rm: 000 BX+SI  001 BX+DI  010 BP+SI  011 BP+DI  100 SI  101 DI
    //       110 (mod==00) disp16 / (else) BP   111 BX
    //   disp: mod=01 disp8(sext), mod=10 disp16, mod=00/rm=110 disp16, else none.
    //   16-bit GPRs: BX=gpr[3], BP=gpr[5], SI=gpr[6], DI=gpr[7] (low 16).
    if (eff_addr) begin
      logic [15:0] ea16_base, ea16_disp;
      unique case (modrm_rm)
        3'b000:  ea16_base = gpr[3][15:0] + gpr[6][15:0];                 // BX+SI
        3'b001:  ea16_base = gpr[3][15:0] + gpr[7][15:0];                 // BX+DI
        3'b010:  ea16_base = gpr[5][15:0] + gpr[6][15:0];                 // BP+SI
        3'b011:  ea16_base = gpr[5][15:0] + gpr[7][15:0];                 // BP+DI
        3'b100:  ea16_base = gpr[6][15:0];                                // SI
        3'b101:  ea16_base = gpr[7][15:0];                                // DI
        3'b110:  ea16_base = (modrm_mod==2'b00) ? 16'd0 : gpr[5][15:0];   // disp16 / BP
        default: ea16_base = gpr[3][15:0];                               // BX (rm=111)
      endcase
      if (modrm_mod==2'b01)
        ea16_disp = {{8{ibuf[m_idx+1][7]}}, ibuf[m_idx+1]};              // disp8 (sext)
      else if (modrm_mod==2'b10 || (modrm_mod==2'b00 && modrm_rm==3'b110))
        ea16_disp = {ibuf[m_idx+2], ibuf[m_idx+1]};                      // disp16
      else
        ea16_disp = 16'd0;
      d_ea = {16'd0, (ea16_base + ea16_disp)};   // 16-bit wrap, zero-extended
      // BP-based 16-bit forms default to SS (stack); others keep DS. A segment-
      // override prefix (already in d_seg) wins. rm=010/011 (BP+idx) and rm=110 with
      // mod!=00 (BP+disp) are BP-relative.
      if (!d_pfx_seg_en &&
          (modrm_rm==3'b010 || modrm_rm==3'b011 ||
           (modrm_rm==3'b110 && modrm_mod!=2'b00)))
        d_seg = 3'(SG_SS);
    end

    d_w = eff_opsize ? 3'd2 : 3'd4;

    if (two_byte) begin
      unique casez (op1)
        // ---- M2S.4 system 0F 00 group: /1 STR, /3 LTR ----------------------
        // 0F 00 /3 LTR r/m16 — load TR from a GDT TSS selector (reads the TSS
        // descriptor, marks it busy). 0F 00 /1 STR r/m16 — store the TR selector.
        // Only the register form (mod==11) is used by the corpus; SLDT(/0) and
        // LLDT(/2)/VERR(/4)/VERW(/5) are not needed here.
        8'h00: begin
          // LTR/STR are SYSTEM instructions: only meaningful in system mode. Gate
          // the decode on sys_mode so user mode keeps its exact pre-M2S.4 behavior
          // (0F 00 was d_unknown -> HALT; the user corpus never uses it, so this
          // keeps `make verify` byte-identical).
          if (sys_mode && modrm_mod==2'b11 && modrm_reg==3'd3) begin // LTR r16
            d_sysop=SYS_LTR; d_src_reg=modrm_rm; d_w=3'd2; d_len=pfx_len+4'd3;
          end else if (sys_mode && modrm_mod==2'b11 && modrm_reg==3'd2) begin // LLDT r16
            // load the LDTR from a GDT LDT descriptor (reuses the S_LTR read FSM).
            d_sysop=SYS_LLDT; d_src_reg=modrm_rm; d_w=3'd2; d_len=pfx_len+4'd3;
          end else if (sys_mode && modrm_mod==2'b11 && modrm_reg==3'd1) begin // STR r16
            d_sysop=SYS_STR; d_dst_reg=modrm_rm; d_writes_reg=1'b1;
            d_w=3'd2; d_len=pfx_len+4'd3;
          end else begin
            d_unknown=1'b1; d_len=pfx_len+4'd2;  // SLDT/LLDT/VERR/VERW/mem deferred
          end
        end
        // ---- 0F 1E / 0F 1F: CET endbr + multi-byte NOP -> NOP --------------
        // 0F 1F /r is the canonical multi-byte NOP; F3 0F 1E FB/FA are the CET
        // endbr32/endbr64 markers (F3 is a legacy prefix here, in pfx_len). On a
        // non-CET CPU these are hint-NOPs, and qemu (our oracle, any -cpu) retires
        // them as NOPs. The core previously hit d_unknown -> HALT, which stranded
        // CET-compiled binaries: musl's __divmoddi4 begins with endbr32, so Quake
        // hung at its first 64-bit divide. Decode the whole 0F 1E/1F space as a
        // NOP, consuming the modrm(+SIB/disp) via mfl_e so the length is exact.
        8'h1E, 8'h1F: begin
          d_is_nop=1'b1;
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
        end
        // ---- M2S.5 RSM (0F AA): resume from System Management Mode ----------
        // RSM restores the CPU state from the SMRAM save-state map and resumes
        // the interrupted program. It is ONLY valid while the CPU is in SMM
        // (HF_SMM); executing it outside SMM is #UD (Pentium Dev. Manual Vol.3
        // §20.1.3.3). Here, inside SMM the FSM runs the S_RSM restore sequence;
        // OUTSIDE SMM (or in user mode) it stays an unknown opcode -> HALT loudly
        // (so a stray 0F AA cannot masquerade as a clean run, and user-mode
        // `make verify` is byte-identical: 0F AA was d_unknown there before).
        8'hAA: begin
          d_len=pfx_len+4'd2;
          if (sys_mode && smm_active) d_rsm=1'b1; else d_unknown=1'b1;
        end
        // ---- M2S.1 system 0F opcodes ---------------------------------------
        8'h01: begin // 0F 01 /2 LGDT, /3 LIDT, /0 SGDT, /1 SIDT (mem operand = 6 bytes)
          if (modrm_reg==3'd2 || modrm_reg==3'd3) begin
            d_sysop=(modrm_reg==3'd2)?SYS_LGDT:SYS_LIDT;
            d_mem_read=1'b1;       // read the 6-byte pseudo-descriptor from memory
            // Operand size (0x66-aware) so S_LGDT masks the base to 24 bits for a 16-bit
            // LGDT/LIDT (IA-32: 16-bit operand -> base[31:24] cleared). Real-mode `lgdt word`
            // is 16-bit; without this the access byte leaks into base[31:24] (0x93088f6b) and
            // the descriptor read lands ~48.5MB off (the Win95 AH=87 PM-entry hang).
            d_w=eff_opsize?3'd2:3'd4;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else if ((modrm_reg==3'd0 || modrm_reg==3'd1) && modrm_mod!=2'b11 && !paging_on) begin
            // M9.5 SGDT (/0) / SIDT (/1): STORE the 6-byte pseudo-descriptor. Not
            // privileged (any CPL). Scoped to !paging_on (the SoC boot path; the
            // 2-beat S_SGDT store does not integrate page translation) -> else HALT.
            d_sysop=(modrm_reg==3'd0)?SYS_SGDT:SYS_SIDT;
            d_mem_write=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else if (modrm_reg==3'd4 && modrm_mod==2'b11) begin
            // SMSW r16 (0F 01 /4, register form): r16 <- CR0[15:0]. Real boot/DOS code
            // (CWSDPMI's PE probe) reads CR0 this way. Reuse the MOVCR_FROM datapath
            // (creg0) at 16-bit width so the reg_merge keeps the dst reg's high 16.
            d_sysop=SYS_MOVCR_FROM; d_sys_creg=3'd0; d_dst_reg=modrm_rm;
            d_writes_reg=1'b1; d_w=3'd2; d_len=pfx_len+4'd3;
          end else if (modrm_reg==3'd7 && modrm_mod!=2'b11) begin
            // INVLPG m (0F 01 /7) — REVIEW_Jul29 H-05. Previously undecoded, so it
            // hit d_unknown and LOUD-HALTED the core. Guests that edit page tables
            // and then invalidate (DPMI hosts, Win95) issue this. No memory access
            // is needed: the operand only names the page. Implemented as a FULL TLB
            // flush (IA-32 allows invalidating more than the named page), driven
            // from the tlb_flush pulse alongside MOV CR3.
            d_sysop=SYS_INVLPG;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else d_unknown=1'b1;  // /4 SMSW mem form, /6 LMSW etc deferred
        end
        // REVIEW2 H-02: MOV CR/DR REQUIRE mod==11 (register form only) -- the mod
        // field was explicitly ignored, so a memory-form encoding executed as a valid
        // control-register operation. And only CR0/CR2/CR3/CR4 exist: core_exec.svh
        // maps EVERY other index to CR4, so the illegal CR1/CR5/CR6/CR7 encodings
        // silently WROTE CR4. Both are #UD.
        // REVIEW2 H-23: CLTS (0F 06) -- clear CR0.TS. Without it a guest cannot exit
        // the #NM handler that H-23's trap now generates, except via a full MOV CR0
        // read-modify-write, so lazy FPU switching would be implementable but absurd.
        // CPL0-only; the priv_fault check in core.sv covers that via SYS_MOVCR_TO.
        // Modelled as a CR0 write with a fixed operand rather than a new sysop: it
        // reuses the existing S_EXEC MOV-CR path, so there is no second CR0 commit
        // site to keep in sync.
        8'h06: begin
          if (sys_mode) begin
            d_sysop=SYS_MOVCR_TO; d_sys_creg=3'd0; d_clts=1'b1;
            d_w=3'd4; d_len=pfx_len+4'd2;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'h20: begin // 0F 20 /r MOV r32, CRn
          if (modrm_mod==2'b11 && (modrm_reg inside {3'd0,3'd2,3'd3,3'd4})) begin
            d_sysop=SYS_MOVCR_FROM; d_sys_creg=modrm_reg; d_dst_reg=modrm_rm;
            d_writes_reg=1'b1; d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd3; end
        end
        8'h22: begin // 0F 22 /r MOV CRn, r32
          if (modrm_mod==2'b11 && (modrm_reg inside {3'd0,3'd2,3'd3,3'd4})) begin
            d_sysop=SYS_MOVCR_TO; d_sys_creg=modrm_reg; d_src_reg=modrm_rm;
            d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd3; end
        end
        8'h21: begin // 0F 21 /r MOV r32, DRn  (M2S.6; mod field ignored, always reg)
          // Gated on sys_mode so USER mode is byte-identical: 0F 21 stays d_unknown
          // (loud HALT) exactly as before M2S.6 — no new user-mode path.
          if (sys_mode && modrm_mod==2'b11) begin   // H-02: register form only
            d_sysop=SYS_MOVDR_FROM; d_sys_creg=modrm_reg; d_dst_reg=modrm_rm;
            d_writes_reg=1'b1; d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'h23: begin // 0F 23 /r MOV DRn, r32  (M2S.6)
          if (sys_mode && modrm_mod==2'b11) begin   // H-02: register form only
            d_sysop=SYS_MOVDR_TO; d_sys_creg=modrm_reg; d_src_reg=modrm_rm;
            d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'b1000_????: begin // Jcc rel16/rel32 (0F 8x)
          // Operand-size-aware (M7.3b): 32-bit mode (every prior user/PM gate,
          // eff_opsize=0) = rel32 / length 6 — UNCHANGED. 16-bit operand mode (real
          // mode without 0x66, or PM with 0x66; eff_opsize=1) = rel16 / length 4,
          // and the taken target truncates EIP to 16 bits (d_br16). The Win95 boot's
          // real-mode SeaBIOS POST uses the 0F 8x rel16 form (e.g. the jnz at
          // 0xe062) — the prior hardcoded rel32 mis-decoded its length.
          d_is_branch=1'b1; d_branch_taken=cond_true(op1[3:0],eflags);
          if (eff_opsize) begin
            d_rel={{16{ibuf[m_idx+1][7]}},ibuf[m_idx+1],ibuf[m_idx]};
            d_br16=1'b1; d_len=pfx_len+4'd4;
          end else begin
            d_rel={ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1],ibuf[m_idx]};
            d_len=pfx_len+4'd6;
          end
        end
        8'b1001_????: begin // SETcc r/m8
          d_kind=K_SETCC; d_w=3'd1; d_cc=op1[3:0];
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        // M9.5 — LSS (0F B2) / LFS (0F B4) / LGS (0F B5): load r16 + SS/FS/GS from a
        // m16:16 far pointer. Same real-mode-16-bit mechanism as LES/LDS (single
        // 4-byte read {sel,off}; GPR<-off, seg<-sel base=sel<<4). Out of scope -> HALT.
        8'hB2, 8'hB4, 8'hB5: begin
          // LSS/LFS/LGS: 16-bit (eff_opsize) reads a 4-byte m16:16 ptr
          // (off=low16, sel=high16); 32-bit (0x66, !eff_opsize) reads a 6-byte m16:32
          // ptr (off=4 bytes @[mem], sel=2 bytes @[mem+4] via a 2nd S_LOAD2 read).
          // PROTECTED mode (DOS-Quake go32 `lss esp,cs:[..]` restores its PM stack after
          // an int-0x31 real-mode-int sim): identical far-ptr read + GPR-offset write;
          // the SEG load walks the GDT/LDT in S_SEGLD (the PM far-ptr arm in
          // core_exec.svh) instead of base=sel<<4. (Was gated to real-mode -> PM HALTed.)
          if (modrm_mod!=2'b11) begin
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
            d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_seg_load=1'b1;
            d_lseg=(op1==8'hB2)?3'(SG_SS):(op1==8'hB4)?3'(SG_FS):3'(SG_GS);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd3; end
        end
        8'hB6,8'hB7,8'hBE,8'hBF: begin // MOVZX/MOVSX
          d_kind=K_EXT; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_ext_signed=(op1==8'hBE)||(op1==8'hBF);
          d_ext_srcw=((op1==8'hB6)||(op1==8'hBE))?3'd1:3'd2;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_src_high8=(d_ext_srcw==3'd1)&&modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'hAF: begin // IMUL r, r/m
          d_kind=K_IMUL2; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hA3,8'hAB,8'hB3,8'hBB: begin // BT/BTS/BTR/BTC reg
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          unique case (op1)
            8'hA3: d_bit_op=3'd4; 8'hAB: d_bit_op=3'd5; 8'hB3: d_bit_op=3'd6;
            default: d_bit_op=3'd7;
          endcase
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_writes_reg=(op1!=8'hA3); d_len=pfx_len+4'd3;
          end else begin
            // memory bit op: BT (A3) reads [mem] (CF only); BTS/BTR/BTC RMW [mem].
            // d_src_reg=modrm_reg is the index reg; idx is masked to the operand size
            // (the huge-offset bit-string addressing is not modeled — not exercised).
            d_mem_read=1'b1; d_mem_dst=1'b1; d_mem_write=(op1!=8'hA3);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'hBA: begin // BT/BTS/BTR/BTC imm
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_bit_imm=1'b1; d_bit_op=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_imm={24'd0,ibuf[m_idx+1]};
            d_writes_reg=(modrm_reg!=3'd4); d_len=pfx_len+4'd4;
          end else begin
            // memory imm bit op: BT (/4) reads [mem]; BTS/BTR/BTC (/5,/6,/7) RMW [mem].
            d_mem_read=1'b1; d_mem_dst=1'b1; d_mem_write=(modrm_reg!=3'd4);
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'hBC,8'hBD: begin // BSF/BSR
          d_kind=K_BITSCAN; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          d_shrd=(op1==8'hBD);
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hA4,8'hA5,8'hAC,8'hAD: begin // SHLD/SHRD
          d_kind=K_SHLDRD; d_writes_flags=1'b1;
          d_shrd=(op1==8'hAC)||(op1==8'hAD);
          d_shift_cl=(op1==8'hA5)||(op1==8'hAD);
          d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm;
            if (d_shift_cl) d_len=pfx_len+4'd3;
            else begin d_shift_imm=ibuf[m_idx+1][4:0]; d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
          end else begin
            // memory destination RMW (SHLD/SHRD Ev,Gv,Ib/CL): read [mem], shift it with
            // src_reg + count, write [mem] back. d_src_reg=modrm_reg (above) is the bits
            // shifted in. Mirrors the K_SHIFT memory RMW (0xC1 /r). Was d_unknown->HALT.
            d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            if (d_shift_cl) d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
            else begin
              d_shift_imm=ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][4:0];
              d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
            end
          end
        end
        8'b1100_1???: begin // BSWAP r32
          d_kind=K_BSWAP; d_writes_reg=1'b1; d_dst_reg=op1[2:0]; d_len=pfx_len+4'd2;
        end
        // ---- 0F B0/B1: CMPXCHG r/m, r ----------------------------------------
        // CMPXCHG r/m,r (accumulator = AL for 0F B0, eAX for 0F B1). It is an RMW:
        //   temp = r/m;  CMP accumulator,temp (sets ZF/CF/PF/AF/SF/OF as the
        //   accumulator-minus-temp subtraction);  if accumulator==temp then
        //   r/m <- src (the reg operand) and ZF=1; else accumulator <- temp and
        //   ZF=0 (the memory dst is written back UNCHANGED to keep the locked RMW
        //   atomic — matches QEMU). q_src_reg carries the reg operand to store;
        //   the destination is q_dst_reg (reg form) or q_ea (memory form). The
        //   compare/flags reuse the ALU_CMP path with a=accumulator, b=temp.
        // The LOCK prefix (F0) is a functional no-op here (already consumed in the
        // prefix loop into pfx_lock); on this in-order single-core the RMW is
        // already atomic. Kept on the proven slow FSM (NP / microcoded). Not gated
        // on proxy_en — a general ISA fix valid in all modes.
        8'hB0,8'hB1: begin
          d_kind=K_CMPXCHG; d_writes_flags=1'b1;
          d_w=(op1==8'hB0)?3'd1:(eff_opsize?3'd2:3'd4);
          d_src_reg=modrm_reg; d_src_high8=(op1==8'hB0)&&modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_dst_high8=(op1==8'hB0)&&modrm_rm[2];
            d_writes_reg=1'b1; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        // ---- 0F C0/C1: XADD r/m, r (exchange-and-add) ------------------------
        // XADD has the SAME operand shape as ADD r/m,r / CMPXCHG (r/m = dst, reg =
        // src). Semantics (Intel): TEMP = SRC + DEST; SRC = DEST; DEST = TEMP — i.e.
        // the destination gets the SUM, the source register gets the OLD destination,
        // and all six ADD flags (CF/PF/AF/ZF/SF/OF) are defined. q_alu_op=ALU_ADD
        // reuses the ALU add (alu_out = dst+src, flags_out = ADD flags); the K_XADD
        // exec arm performs both writebacks. 0F C0 is byte (high-8 regs honoured);
        // 0F C1 is 16/32 per 0x66. Reg-form (mod==11) and memory-RMW both handled.
        // LOCK (F0) is a functional no-op (the in-order single core RMW is atomic).
        // Was d_unknown->HALT before; the user corpus never executes it -> byte-id.
        8'hC0,8'hC1: begin
          d_kind=K_XADD; d_alu_op=ALU_ADD; d_writes_flags=1'b1;
          d_w=(op1==8'hC0)?3'd1:(eff_opsize?3'd2:3'd4);
          d_src_reg=modrm_reg; d_src_high8=(op1==8'hC0)&&modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_dst_high8=(op1==8'hC0)&&modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        // ---- 0F A0/A8 PUSH FS / PUSH GS --------------------------------------
        // Two-byte one-operand PUSH of the 16-bit segment selector (zero-extended to
        // 32 unless a 0x66 operand-size prefix keeps it 16). Reuses the one-byte
        // PUSH-sreg datapath (d_push_sreg: store data = seg_sel[d_sys_sreg]; K_ALU
        // default kind drives the push). The POP counterparts (0F A1/A9) reload the
        // selector + hidden base via the SAME d_pop_sreg path as the one-byte POP
        // ES/SS/DS (07/17/1F): real/v86 base=sel<<4, protected-mode walks the GDT/LDT
        // descriptor in S_SEGLD (target = q_sys_sreg). DOS-Quake's go32/CWSDPMI reflector
        // does `pop fs` (0F A1) — without this the core HALTed loudly on it.
        8'hA0: begin d_len=pfx_len+4'd2; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_FS); d_w=eff_opsize?3'd2:3'd4; end
        8'hA8: begin d_len=pfx_len+4'd2; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_GS); d_w=eff_opsize?3'd2:3'd4; end
        8'hA1: begin d_len=pfx_len+4'd2; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_FS); d_w=eff_opsize?3'd2:3'd4; end
        8'hA9: begin d_len=pfx_len+4'd2; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_GS); d_w=eff_opsize?3'd2:3'd4; end
        // ---- 0F C7: CMPXCHG8B (/1, memory only) ------------------------------
        // The ONLY valid form is a MEMORY destination (mod != 11). A REGISTER
        // destination (mod == 11) is an invalid opcode (#UD). The clean core does
        // not implement CMPXCHG8B's memory form either (M2S), so both forms are
        // d_unknown here -> HALT loudly. We additionally tag the invalid
        // register-destination form (mod==11) as d_f00f so the FSM can reproduce
        // Erratum 81 (the LOCK + reg-dst HANG) when errata_en[ERR_F00F] is set.
        8'hC7: begin
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          if (modrm_mod!=2'b11 && modrm_reg==3'd1) begin
            // CMPXCHG8B m64 (the ONLY valid form). EDX:EAX vs [m64]; if equal then
            // [m64] <- ECX:EBX and ZF=1, else EDX:EAX <- [m64] and ZF=0. ONLY ZF is
            // affected (CF/PF/AF/SF/OF unchanged). 64-bit RMW: two word loads
            // (S_LOAD [m]=low vs EAX, S_LOAD2 [m+4]=high vs EDX), then a conditional
            // two-word store (EBX->[m], ECX->[m+4]) in S_STORE. LOCK (F0) is a
            // functional no-op on this in-order single core.
            d_kind=K_CX8B; d_mem_read=1'b1; d_w=3'd4;
          end else begin
            d_unknown=1'b1; d_len=pfx_len+4'd3;
            if (modrm_mod==2'b11 && modrm_reg==3'd1) d_f00f=1'b1;  // /1 reg-dst (Erratum 81)
          end
        end
        // ---- 0F A2: CPUID -----------------------------------------------------
        // CPUID is a no-operand instruction (no ModRM): leaf = eAX (subleaf = eCX,
        // unused by the leaves this boot touches). It writes eax/ebx/ecx/edx and
        // touches NO flags. The result is a pure FUNCTION of the leaf for the modeled
        // CPU (qemu `-cpu pentium`), so this is a deterministic ISA implementation —
        // NOT injected environment. The leaf->result table lives in S_EXEC (K_CPUID)
        // and is gated on cosim_en OR soc_en so the existing user-mode corpus (which
        // never executes CPUID, both off) is byte-identical: outside co-sim AND outside
        // the SoC, CPUID stays the loud HALT (d_unknown) it has always been. The SoC
        // (soc_en=1, cosim_en=0) ungates it because real boot firmware probes CPUID on
        // entry; the leaf table is the same qemu `-cpu pentium` model the SoC golden uses
        // (verif/sys/tests/psoccpuid). Length is always pfx_len+2 (decode is
        // unconditional, so even the gated HALT advances correctly is moot — HALT
        // never retires — but the length is right for a clean characterization).
        8'hA2: begin
          d_len=pfx_len+4'd2;
          if (cosim_en || soc_en) begin
            d_kind=K_CPUID; d_writes_reg=1'b1;  // EXEC writes all 4 GPRs directly
          end else d_unknown=1'b1;              // out-of-scope in user mode -> HALT
        end
        // ---- 0F 31: RDTSC — read the 64-bit time-stamp counter into EDX:EAX.
        // Ungated like CPUID (cosim_en || soc_en): real boot firmware (SeaBIOS
        // calibrates the TSC against PIT ch2) needs it; our CPUID advertises the
        // TSC feature (leaf-1 EDX bit 4 = 1). The user-mode corpus has both off, so
        // it stays the loud HALT there — and the TSC value is a free-running cycle
        // count, inherently not per-record-diffable vs qemu (the SeaBIOS path that
        // uses it is free-run graded, not single-step). CR4.TSD privilege check is
        // not modeled (firmware runs CPL0 with TSD=0). EXEC writes EDX:EAX directly.
        8'h31: begin
          d_len=pfx_len+4'd2;
          if (cosim_en || soc_en) begin
            d_kind=K_RDTSC; d_writes_reg=1'b1;  // EXEC writes EDX:EAX from `tsc`
          end else d_unknown=1'b1;              // out-of-scope in user mode -> HALT
        end
        // ---- 0F 08 INVD / 0F 09 WBINVD: cache invalidate / write-back+invalidate.
        // Privileged (CPL0) cache-management ops with NO architectural register/flag
        // effect — qemu's TCG treats both as NOPs (no modeled cache writeback), and
        // Ventium's caches stay coherent with the flat memory model, so they retire as
        // NOPs. Real boot firmware (SeaBIOS shadows the BIOS / sets caching) uses WBINVD.
        // Ungated like CPUID/RDTSC (cosim_en || soc_en); user-mode corpus keeps the HALT.
        8'h08, 8'h09: begin
          d_len=pfx_len+4'd2;
          // REVIEW_aug2 H-06: these are CPL0-ONLY. Retiring them as NOPs is fine for
          // their (absent) architectural effect, but an anonymous NOP is invisible to
          // the privilege check, so CPL3 code could execute WBINVD. d_cacheinv gives
          // core.sv's one privilege predicate something to reject.
          if (cosim_en || soc_en) begin d_is_nop=1'b1; d_cacheinv=1'b1; end
          else d_unknown=1'b1;
        end
        // ---- 0F 0B: UD2, the architecturally-undefined opcode -> #UD (vector 6).
        // In SYSTEM mode it DELIVERS #UD through the IDT (a FAULT: pushes the
        // faulting EIP); in user mode there is no IDT, so it HALTs loudly as an
        // out-of-scope opcode (unchanged). #UD carries NO error code.
        8'h0B: begin
          d_len=pfx_len+4'd2;
          if (sys_mode) d_ud2=1'b1; else d_unknown=1'b1;
        end
        default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
      endcase
    end else begin
      unique casez (op0)
        8'b1011_0???: begin // MOV r8, imm8
          d_len=pfx_len+4'd2; d_is_mov=1'b1; d_writes_reg=1'b1; d_w=3'd1;
          d_dst_reg=op0[2:0]; d_dst_high8=op0[2]; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          d_imm={24'd0,ibuf[pfx_len+1]};
        end
        8'b1011_1???: begin // MOV r16/32, imm
          d_is_mov=1'b1; d_writes_reg=1'b1; d_dst_reg=op0[2:0]; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'b0100_0???: begin // INC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_INC; d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0100_1???: begin // DEC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_DEC; d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0101_0???: begin // PUSH r16/32
          d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1; d_src_reg=op0[2:0];
          d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0101_1???: begin // POP r16/32
          d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1; d_writes_reg=1'b1;
          d_dst_reg=op0[2:0]; d_w=eff_opsize?3'd2:3'd4;
        end
        // ---- F3: one-byte PUSH/POP segment register (06/0E/16/1E push es/cs/ss/ds,
        // 07/17/1F pop es/ss/ds — there is no POP CS, 0x0F is the 0F escape). Real
        // boot firmware (SeaBIOS's 16<->32 call32 trampoline) pushes CS to build an
        // iret far-return frame. The push value is the 16-bit selector (zero-extended
        // to 32 under a 0x66 operand-size prefix); POP reloads the selector and, in
        // real/v86, the base = sel<<4 (the only path these reach in firmware). They
        // were d_unknown->HALT before; the user corpus never executes them, so the
        // default `make verify` build stays byte-identical. K_ALU (default kind) so the
        // push data-mux / pop writeback below service them.
        8'h06: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_ES); d_w=eff_opsize?3'd2:3'd4; end
        8'h0E: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_CS); d_w=eff_opsize?3'd2:3'd4; end
        8'h16: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_SS); d_w=eff_opsize?3'd2:3'd4; end
        8'h1E: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_DS); d_w=eff_opsize?3'd2:3'd4; end
        8'h07: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_ES); d_w=eff_opsize?3'd2:3'd4; end
        8'h17: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_SS); d_w=eff_opsize?3'd2:3'd4; end
        8'h1F: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_DS); d_w=eff_opsize?3'd2:3'd4; end
        8'h60: begin d_kind=K_STKMISC; d_sm=SM_PUSHA; d_len=pfx_len+4'd1; d_w=eff_opsize?3'd2:3'd4; end
        8'h61: begin d_kind=K_STKMISC; d_sm=SM_POPA;  d_len=pfx_len+4'd1; d_w=eff_opsize?3'd2:3'd4; end
        // ---- 0x62: BOUND r16/32, m16&16/m32&32 (array index bounds check) -----
        // index = modrm_reg; [mem] = lower bound, [mem+w] = upper bound (SIGNED).
        // If index < lower OR index > upper -> #BR (vector 5). No writeback, no
        // flags otherwise. MEMORY operand only — the register form (mod==11) is an
        // invalid opcode (#UD) -> loud HALT. The two bounds are read via S_LOAD
        // ([mem]) then S_LOAD2 ([mem+w]); the compare + #BR/retire is in S_EXEC.
        8'h62: begin
          if (modrm_mod!=2'b11) begin
            d_kind=K_BOUND; d_mem_read=1'b1; d_src_reg=modrm_reg;
            d_w=eff_opsize?3'd2:3'd4;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end   // reg form -> #UD
        end
        8'h68: begin // PUSH imm
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'h6A: begin // PUSH imm8 (sign-ext)
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1; d_w=eff_opsize?3'd2:3'd4;
          d_imm={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'h69: begin // IMUL r, r/m, imm32
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]};
            d_len=pfx_len+4'd6;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
          end
        end
        8'h6B: begin // IMUL r, r/m, imm8
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={{24{ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'b00??_?000: begin // ALU r/m8, r8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?001: begin // ALU r/m16/32, r16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?010: begin // ALU r8, r/m8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?011: begin // ALU r16/32, r/m16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?100: begin // ALU AL, imm8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'b00??_?101: begin // ALU eAX, imm16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        // 0x82 is an undocumented alias of 0x80 (group-1 r/m8, imm8) — same ModRM,
        // same imm8, same /digit ALU op. Real P5 silicon (and QEMU) decode it
        // identically; folding it here closes the alias gap. (Compilers never emit
        // it, so the corpus is byte-identical; t_grp1alias uses a .byte 0x82.)
        8'h80, 8'h82: begin // group1 r/m8, imm8
          d_w=3'd1; d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h81: begin // group1 r/m16/32, imm16/32
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            if (eff_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'h83: begin // group1 r/m16/32, imm8 sign-ext
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1; d_w=eff_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            d_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={{24{ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                   ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h84: begin // TEST r/m8, r8
          d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h85: begin // TEST r/m16/32, r16/32
          d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h86: begin // XCHG r/m8, r8
          d_kind=K_XCHG; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h87: begin // XCHG r/m16/32, r16/32
          d_kind=K_XCHG; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h88: begin // MOV r/m8, r8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h89: begin // MOV r/m16/32, r16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8A: begin // MOV r8, r/m8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_writes_reg=1'b1; d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8B: begin // MOV r16/32, r/m16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        // M9.5 — LES (0xC4) / LDS (0xC5): load r16 + a segment register from a
        // m16:16 far pointer. REAL-MODE 16-bit only: a single 4-byte read returns
        // {sel, off}; the GPR gets off (a normal MOV writeback), the segment reg
        // gets sel (base=sel<<4) via the q_seg_load exec hook. The reg form is #UD,
        // and 32-bit (0x66) / protected-mode are out of scope -> HALT loudly.
        8'hC4, 8'hC5: begin
          if (modrm_mod!=2'b11 && seg_real) begin   // 16b: m16:16; 32b (0x66): m16:32 (2nd read)
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
            d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
            d_seg_load=1'b1; d_lseg=(op0==8'hC4)?3'(SG_ES):3'(SG_DS);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'h8C: begin // MOV r/m16, Sreg  (M2S.1)
          // store the selector value of segment modrm_reg into r/m16. Reg form =
          // SYS_MOVSREG_FROM (writes a GPR). F3 MEMORY-dest form (mod!=11): real
          // boot firmware (SeaBIOS's call16/call32 trampoline SAVES es/ss/etc into a
          // struct). Storing a selector is mode-independent (no descriptor), so it
          // routes as a normal MOV-store (d_is_mov + d_mem_write) with the data taken
          // from seg_sel via d_store_sreg. Gated sys_mode so the user-mode corpus keeps
          // its HALT (byte-identical); reg form unchanged.
          if (modrm_mod==2'b11) begin
            d_sysop=SYS_MOVSREG_FROM; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else if (sys_mode) begin
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_w=3'd2;
            d_store_sreg=1'b1; d_sys_sreg=sreg_idx(modrm_reg);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin
            d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'h8D: begin // LEA
          d_is_lea=1'b1; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
        end
        8'h8E: begin // MOV Sreg, r/m16  (M2S.1)
          // load segment register modrm_reg from r/m16. Reg-form source: the M2S.1
          // SYS_MOVSREG_TO path (real -> base=sel<<4 in S_EXEC; PM -> S_SEGLD GDT walk).
          // F3 MEMORY-source form (mod!=11): real/v86 boot firmware (SeaBIOS's call32
          // return loads ds/es from a saved struct). Read the 2-byte selector and load
          // it via the LES/LDS seg-load hook's LOW-half variant (base=sel<<4). In
          // PROTECTED mode the loaded selector is walked through the GDT/LDT instead
          // (S_EXEC latches the loaded sel + routes to S_SEGLD) — CWSDPMI's fault
          // handlers restore the client's segs via `mov fs,[mem]` in PM. The user
          // corpus never uses the mem form, so `make verify` stays byte-identical.
          if (modrm_mod==2'b11) begin
            d_sysop=SYS_MOVSREG_TO; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
            d_src_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else begin
            d_mem_read=1'b1; d_w=3'd2;
            d_seg_load=1'b1; d_seg_load_lo=1'b1; d_lseg=sreg_idx(modrm_reg);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'h8F: begin // POP r/m
          d_is_pop=1'b1; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b1001_0???: begin // NOP / XCHG eAX,r
          if (op0==8'h90 && !eff_opsize) begin d_is_nop=1'b1; d_len=pfx_len+4'd1; end
          else begin d_kind=K_XCHG; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_src_reg=op0[2:0]; d_len=pfx_len+4'd1; end
        end
        8'h98: begin d_kind=K_CONV; d_conv_cdq=1'b0; d_len=pfx_len+4'd1; end
        8'h99: begin d_kind=K_CONV; d_conv_cdq=1'b1; d_len=pfx_len+4'd1; end
        // FWAIT/WAIT (9B): wait for pending unmasked x87 exceptions. With the FPU
        // exception masks at their (default) masked state — as glibc/musl libm
        // (floor/ceil via FSTCW) and Quake leave them — there is nothing to
        // service, so it retires as a 1-byte NOP. (Was undecoded -> S_HALT hang.)
        8'h9B: begin d_is_nop=1'b1; d_len=pfx_len+4'd1; end
        8'h9C: begin d_kind=K_STKMISC; d_sm=SM_PUSHF; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9D: begin d_kind=K_STKMISC; d_sm=SM_POPF;  d_mem_read=1'b1;  d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9E: begin d_kind=K_STKMISC; d_sm=SM_SAHF; d_len=pfx_len+4'd1; end
        8'h9F: begin d_kind=K_STKMISC; d_sm=SM_LAHF; d_len=pfx_len+4'd1; end
        // ---- BCD / ASCII-adjust (review fidelity closure; QEMU-exact in S_EXEC) ----
        // All six write AX (d_w=2, dst=EAX) and flags; the BCD AX result + defined
        // flags are computed combinationally below and override alu_out/flags_out.
        // ASCII forms 0xD4/0xD5 take an imm8 "base" (ibuf[pfx_len+1]); 0x27/0x2F/
        // 0x37/0x3F are 1-byte no-operand. (These previously fell to d_unknown/HALT.)
        8'h37: begin d_kind=K_ALU; d_alu_op=ALU_AAA; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h3F: begin d_kind=K_ALU; d_alu_op=ALU_AAS; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h27: begin d_kind=K_ALU; d_alu_op=ALU_DAA; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h2F: begin d_kind=K_ALU; d_alu_op=ALU_DAS; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'hD4: begin d_kind=K_ALU; d_alu_op=ALU_AAM; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_use_imm=1'b1;
                     d_imm={24'd0, ibuf[pfx_len+4'd1]}; d_len=pfx_len+4'd2; end
        8'hD5: begin d_kind=K_ALU; d_alu_op=ALU_AAD; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_use_imm=1'b1;
                     d_imm={24'd0, ibuf[pfx_len+4'd1]}; d_len=pfx_len+4'd2; end
        // MOV moffs (A0-A3): the moffs (absolute displacement) width follows the
        // EFFECTIVE ADDRESS size — 2 bytes under 16-bit addressing (real mode / V86
        // without a 0x67 prefix; eff_addr==1), 4 bytes under 32-bit addressing.
        // Previously hardcoded 4-byte (d_len pfx_len+5), which over-consumed 2 bytes
        // and desynced the stream for a 16-bit-address `66 a3 disp16` store — exactly
        // the V86 task's `mov %eax,%ds:0`. M0-M6/sys gates only ever hit the 32-bit
        // form, so the eff_addr branch is additive (bit-identical where eff_addr==0).
        // MOV moffs (A0-A3): the moffs form has NO ModRM byte — its bytes are the raw
        // absolute displacement. The ea16 block above unconditionally treats ibuf[m_idx]
        // as a ModRM and (for a BP-based rm=010/011 or rm=110/mod!=00) forces d_seg=SS.
        // For a moffs whose displacement's low byte aliases such a rm (e.g. 0x0002 -> rm=010),
        // that wrongly selects SS instead of the DS default, so the absolute access uses the
        // (usually null) stack base — e.g. the VGA-BIOS option-ROM scan's `mov al,[0xc0002]`
        // read SS:2 (=0) instead of DS:2, so the ROM length came back 0 and POST looped
        // forever. Re-assert the moffs default segment (DS, or a real seg-override prefix).
        8'hA0: begin // MOV AL, moffs8 (8-bit load, preserve [31:8])
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=3'd1; d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA1: begin // MOV eAX, moffs
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=eff_opsize?3'd2:3'd4; d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA2: begin // MOV moffs8, AL (8-bit store)
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=3'd1; d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA3: begin // MOV moffs, eAX
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=eff_opsize?3'd2:3'd4; d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA8: begin d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2; end
        8'hA9: begin d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        // string ops
        8'hA4: begin d_kind=K_STR; d_st=ST_MOVS; d_w=3'd1; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA5: begin d_kind=K_STR; d_st=ST_MOVS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAA: begin d_kind=K_STR; d_st=ST_STOS; d_w=3'd1; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAB: begin d_kind=K_STR; d_st=ST_STOS; d_w=eff_opsize?3'd2:3'd4; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAC: begin d_kind=K_STR; d_st=ST_LODS; d_w=3'd1; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAD: begin d_kind=K_STR; d_st=ST_LODS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAE: begin d_kind=K_STR; d_st=ST_SCAS; d_w=3'd1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAF: begin d_kind=K_STR; d_st=ST_SCAS; d_w=eff_opsize?3'd2:3'd4; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA6: begin d_kind=K_STR; d_st=ST_CMPS; d_w=3'd1; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA7: begin d_kind=K_STR; d_st=ST_CMPS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        // ---- 6C/6D: INS — port-input string (the co-sim's only string-I/O op) ----
        // INSB (6C) / INSW/D (6D): read a byte/word/dword from port DX and STORE it
        // to ES:[EDI], then EDI += width (DF=0 forward). With a REP prefix it iterates
        // ECX times — each element is its own retire record at the same PC (exactly
        // like the golden's `rep insb` at 0xEBB07, ecx=4, port 0x511 fwcfg). It is a
        // STRING op (K_STR / ST_INS, d_str_storedi) AND a port-input (d_io) so the
        // co-sim's recorded dev_in value is the source of each element (the sole
        // injected environment). The dedicated S_INS state does the per-element IO
        // handshake; the existing K_STR S_STORE path writes [EDI] and loops/retires.
        // Gated on cosim_en (mirrors the IN/OUT decode): outside co-sim INS HALTs
        // loudly (out-of-scope, like every other port I/O) so the corpus is unchanged.
        // Width: byte for 6C; eff-opsize (16/32) for 6D. The boot only uses 6C, but
        // 6D is decoded identically for completeness (same S_INS path, wider element).
        8'h6C, 8'h6D: begin
          // INS/REP INS uses the SAME S_INS per-element IO handshake as the single IN,
          // so it works under soc_en too (SeaBIOS bulk-reads fw_cfg via `rep insb`).
          // Outside both (user mode) it stays the loud HALT. Default build unaffected.
          if (cosim_en || soc_en) begin
            d_kind=K_STR; d_st=ST_INS; d_str_storedi=1'b1; d_mem_write=1'b1;
            d_w=(op0==8'h6C) ? 3'd1 : (eff_opsize?3'd2:3'd4);
            d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b0;  // port is DX (resolved at issue)
            d_io_w=d_w;
            d_len=pfx_len+4'd1;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd1; end
        end
        // OUTSB (6E) / OUTSW/D (6F): read a byte/word/dword from DS:[ESI] (segment
        // overridable) and write it to port DX, ESI += width; REP iterates ECX times.
        // The MIRROR of INS: a K_STR (ST_OUTS, d_str_loadsi) whose element goes through
        // the normal S_LOAD slow-load, then a per-element S_IO OUT handshake (the K_STR
        // S_EXEC arm routes ST_OUTS to S_IO with the loaded element on io_wdata, and
        // S_IO retires with str_next_eip so REP loops at the same PC). First exercised
        // by Win95's IDE PIO disk WRITE (REP OUTSW to port 0x1F0) — was undecoded ->
        // the guest HALTed at the first disk write and the daemon spun forever.
        8'h6E, 8'h6F: begin
          if (cosim_en || soc_en) begin
            d_kind=K_STR; d_st=ST_OUTS; d_str_loadsi=1'b1; d_mem_read=1'b1;
            d_w=(op0==8'h6E) ? 3'd1 : (eff_opsize?3'd2:3'd4);
            d_io=1'b1; d_io_write=1'b1; d_io_imm=1'b0;  // port is DX (resolved at issue)
            d_io_w=d_w;
            d_len=pfx_len+4'd1;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd1; end
        end
        8'hC6: begin // MOV r/m8, imm8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1; d_w=3'd1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hC7: begin // MOV r/m16/32, imm
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm;
            if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            if (eff_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'hD0,8'hD1,8'hD2,8'hD3: begin // shift/rotate by 1 / CL
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hD0||op0==8'hD2)?3'd1:(eff_opsize?3'd2:3'd4);
          d_shift_one=(op0==8'hD0||op0==8'hD1);
          d_shift_cl=(op0==8'hD2||op0==8'hD3);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hC0,8'hC1: begin // shift/rotate by imm8
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hC0)?3'd1:(eff_opsize?3'd2:3'd4);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
            d_shift_imm=ibuf[m_idx+1][4:0]; d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_shift_imm=ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][4:0];
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hF6,8'hF7: begin // group3
          d_w=(op0==8'hF6)?3'd1:(eff_opsize?3'd2:3'd4);
          unique case (modrm_reg)
            3'd0,3'd1: begin // TEST r/m, imm
              d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_use_imm=1'b1;
              if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
                if (d_w==3'd1) begin d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3; end
                else if (d_w==3'd2) begin d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
                else begin d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
              end else begin
                // TEST mem, imm — read the operand, AND with imm, set flags only
                // (no write). The M1-M6 user corpus never used the memory form, so
                // it previously HALTed (d_unknown); Quake's musl uses it (e.g.
                // `test byte [esp+8], 0x10`). The imm follows the full ModR/M+SIB+
                // disp, so its offset is the operand length minus the imm width.
                d_mem_read=1'b1; d_mem_dst=1'b1;
                begin
                  logic [3:0] ml;
                  ml = mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
                  if (d_w==3'd1) begin
                    d_imm={24'd0,ibuf[m_idx+ml]};                 // imm8 after the operand
                    d_len=m_idx+ml+4'd1;
                  end else if (d_w==3'd2) begin
                    d_imm={16'd0,ibuf[m_idx+ml+1],ibuf[m_idx+ml]};
                    d_len=m_idx+ml+4'd2;
                  end else begin
                    d_imm={ibuf[m_idx+ml+3],ibuf[m_idx+ml+2],ibuf[m_idx+ml+1],ibuf[m_idx+ml]};
                    d_len=m_idx+ml+4'd4;
                  end
                end
              end
            end
            3'd2: begin // NOT
              d_alu_op=ALU_NOT;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd3: begin // NEG
              d_alu_op=ALU_NEG; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            default: begin // MUL/IMUL/DIV/IDIV
              d_kind=K_MULDIV; d_md=modrm_reg; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
          endcase
        end
        8'hFE: begin // INC/DEC r/m8
          d_w=3'd1; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hFF: begin
          unique case (modrm_reg)
            3'd0,3'd1: begin // INC/DEC r/m16/32
              d_w=eff_opsize?3'd2:3'd4; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd2: begin // CALL r/m near
              // F3: push width follows the operand size (16-bit real-mode `call
              // r/m16` pushes 2 bytes / SP-=2, exactly like E8 CALLREL). Was a
              // hard-coded d_w=4, which leaked SP by 2 per call/ret pair in
              // 16-bit code. eff_opsize=0 in every flat gate -> byte-identical.
              d_kind=K_CTRL; d_ct=CT_CALLIND; d_mem_write=1'b1;
              d_w=eff_opsize?3'd2:3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd4: begin // JMP r/m near
              d_kind=K_CTRL; d_ct=CT_JMPIND;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd6: begin // PUSH r/m
              d_is_push=1'b1; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            // F3 — FF /3 CALLF m16:16 / FF /5 JMPF m16:16 (far indirect call/jump
            // THROUGH MEMORY): read the 4-byte {offset,selector} far pointer from
            // [mem], then a far transfer. (FreeDOS does `jmp far [bp+0x5a]`.) These
            // are MEMORY-ONLY (reg form mod=11 is invalid -> #UD/HALT). Gated real
            // mode (seg_real && !paging_on) like the direct far CALL/JMP; PM call/jmp
            // gates are out of scope. d_callf_mem/d_jmpf_mem are serviced after the
            // S_LOAD reads the pointer: JMPF loads CS:IP inline, CALLF stages it then
            // S_LCALL pushes CS:next_eip + loads.
            3'd3: begin // CALLF m16:16 (16-bit) / m16:32 (0x66, 32-bit far ptr)
              // MEMORY form only (reg mod=11 is invalid -> #UD). Both REAL and
              // PROTECTED mode: the servicing reads the far pointer, then real mode
              // loads CS.base=sel<<4 inline while PM hands off to S_LCALL->S_LJMP
              // (descriptor load, incl. LDT selectors). Quake's DOS/4GW extender uses
              // the PM indirect far CALL/JMP; Win95 does not, so this was deferred.
              if (modrm_mod!=2'b11) begin
                d_callf_mem=1'b1; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
                d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
              end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
            end
            3'd5: begin // JMPF m16:16 (16-bit) / m16:32 (0x66, 32-bit far ptr)
              if (modrm_mod!=2'b11) begin
                d_jmpf_mem=1'b1; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
                d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
              end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
            end
            default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
          endcase
        end
        8'hEB: begin d_len=pfx_len+4'd2; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; d_br16=eff_opsize; end
        8'hE9: begin d_is_branch=1'b1; d_branch_taken=1'b1;
          // JMP rel16/rel32 (M7.3b operand-size-aware). 32-bit (eff_opsize=0): rel32
          // / length 5 — UNCHANGED. 16-bit (real-mode SeaBIOS, e.g. the jmp at
          // 0xe076): rel16 / length 3, target truncated to 16 bits (d_br16).
          if (eff_opsize) begin
            d_rel={{16{ibuf[pfx_len+2][7]}},ibuf[pfx_len+2],ibuf[pfx_len+1]};
            d_br16=1'b1; d_len=pfx_len+4'd3;
          end else begin
            d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
            d_len=pfx_len+4'd5;
          end
        end
        8'b0111_????: begin d_len=pfx_len+4'd2; d_is_branch=1'b1;
          d_branch_taken=cond_true(op0[3:0],eflags); d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]};
          d_br16=eff_opsize; end
        8'hE8: begin d_kind=K_CTRL; d_ct=CT_CALLREL; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4;
          // 0x66 near CALL: 16-bit rel (cw), push 16-bit next-IP, ESP-=2, and
          // EIP=(next_eip+rel16)&0xFFFF (operand-size-16 truncates EIP).
          if (eff_opsize) begin d_rel={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hC3: begin d_kind=K_CTRL; d_ct=CT_RETN; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hC2: begin d_kind=K_CTRL; d_ct=CT_RETN_IMM; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
          d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
        // M9.5 — RETF (far return): pop IP then CS (2 beats), ESP += 2w (+imm16). The
        // S_RETF state does the stack pops + the real-mode CS load (base=sel<<4). The
        // routing (real-mode only; PM RETF HALTs) is in core_fetch_decode.svh.
        8'hCB: begin d_sysop=SYS_RETF; d_ret_imm=16'd0; d_w=eff_opsize?3'd2:3'd4;
          d_len=pfx_len+4'd1; end
        8'hCA: begin d_sysop=SYS_RETF; d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd3; end
        8'hC9: begin d_kind=K_STKMISC; d_sm=SM_LEAVE; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        // ---- C8: ENTER imm16, imm8 (make a stack frame) ----------------------
        // ENTER alloc,level:  push EBP; FrameTemp=ESP; (level-1 nested-display
        // copies + push FrameTemp); EBP=FrameTemp; ESP=ESP-alloc. We implement the
        // form compilers actually emit: 32-bit operand size, nesting LEVEL 0, which
        // reduces to  push EBP; EBP=ESP; ESP=ESP-alloc  — a single push + register
        // update (modelled as SM_ENTER, finalized in S_STORE). The nested form
        // (level>0, a read+push micro-loop) and the 0x66 16-bit form stay the loud
        // HALT (d_unknown) — they never appear in the user corpus. encoding: C8 iw ib
        // (alloc16 = ib1:ib0, level = ib2). Was d_unknown->HALT before.
        8'hC8: begin
          d_len=pfx_len+4'd4;
          // ENTER alloc,0 (level 0). The frame width follows the operand size:
          // 32-bit (eff_opsize=0) pushes EBP+4-byte frame; 16-bit (eff_opsize=1, the
          // real-mode form DOS Quake's CWSDPMI uses) pushes BP+2-byte frame. Both
          // share the C8 iw ib encoding (alloc16=ib1:ib0, level=ib2). The nested form
          // (level>0, a read+push micro-loop) stays the loud HALT (d_unknown).
          // d_imm = {level[4:0] (imm8 mod 32), alloc16}. level 0 => the existing
          // single-push S_STORE form; level>0 => the nested display-copy micro-sequence
          // (S_ENTER). The level lives in d_imm[20:16]; alloc stays d_imm[15:0] so the
          // level-0 path (which reads q_imm[15:0]) is byte-identical.
          d_kind=K_STKMISC; d_sm=SM_ENTER; d_mem_write=1'b1;
          d_w = eff_opsize ? 3'd2 : 3'd4;                       // 16-bit (real) vs 32-bit frame
          d_imm={11'd0, ibuf[pfx_len+3][4:0], ibuf[pfx_len+2], ibuf[pfx_len+1]};
        end
        // ---- D7: XLATB — AL <- [DS:(E)BX + zero-extend(AL)] (table lookup) ----
        // One-byte, no ModR/M. The default (no 0x67) 32-bit address form: linear
        // EA = DS.base + EBX + AL; a segment-override prefix redirects DS (handled
        // by dbase/q_seg). Touches no flags. The byte-load address is driven in the
        // S_LOAD bus arm (q_xlat); S_EXEC writes AL from the loaded byte.
        // REVIEW_Jul29 M-06: the 0x67 16-bit-address form (BX, not EBX) is NOW
        // modelled — the bus arm selects BX vs EBX on q_cnt16 (the latched
        // effective-address-size flag). It used to always use EBX, which is a
        // deterministic wrong address in real mode / under 0x67 when EBX[31:16]!=0.
        8'hD7: begin d_xlat=1'b1; d_mem_read=1'b1; d_w=3'd1; d_len=pfx_len+4'd1; end
        8'hE2: begin d_kind=K_CTRL; d_ct=CT_LOOP;   d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE1: begin d_kind=K_CTRL; d_ct=CT_LOOPE;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE0: begin d_kind=K_CTRL; d_ct=CT_LOOPNE; d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE3: begin d_kind=K_CTRL; d_ct=CT_JECXZ;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hFC: begin d_cld=1'b1; d_len=pfx_len+4'd1; end
        8'hFD: begin d_std=1'b1; d_len=pfx_len+4'd1; end
        8'hF8: begin d_clc=1'b1; d_len=pfx_len+4'd1; end // CLC: CF<-0
        8'hF9: begin d_stc=1'b1; d_len=pfx_len+4'd1; end // STC: CF<-1
        8'hF5: begin d_cmc=1'b1; d_len=pfx_len+4'd1; end // CMC: CF<-~CF
        8'hFA: begin d_cli=1'b1; d_len=pfx_len+4'd1; end // CLI: IF<-0 (M2S.1)
        8'hFB: begin d_sti=1'b1; d_len=pfx_len+4'd1; end // STI: IF<-1 (M2S.1)
        // INT n (CD ib): in USER mode INT 0x80 is the syscall HALT (unchanged —
        // no IDT in linux-user). In SYSTEM mode it is a software interrupt that
        // vectors through IDT[n] (a TRAP: pushes the NEXT EIP so IRET resumes
        // after the INT). The decode is gated on sys_mode so user mode is byte-
        // identical; a non-0x80 INT in user mode still HALTs loudly (out of scope).
        8'hCC: begin // INT3 (#BP, vector 3) — TRAP
          d_len=pfx_len+4'd1;
          // user mode: keep the prior loud-HALT (d_unknown) exactly so the M0-M6
          // user gate stays BIT-IDENTICAL (0xCC was an unknown opcode before M2S.3).
          if (sys_mode) begin d_int=1'b1; d_int_vec=8'd3; end else d_unknown=1'b1;
        end
        8'hCD: begin
          d_len=pfx_len+4'd2;
          if (sys_mode) begin d_int=1'b1; d_int_imm=1'b1; d_int_vec=ibuf[pfx_len+1]; end
          else begin
            // user mode: int 0x80 = the syscall site. Without the proxy it HALTs
            // (M0-M6 behaviour, unchanged). d_int80 flags it so the S_DECODE arm
            // can route it to the proxy when proxy_en is set.
            d_halt  = (ibuf[pfx_len+1]==8'h80);
            d_int80 = (ibuf[pfx_len+1]==8'h80);
          end
        end
        8'hCE: begin // INTO (#OF, vector 4) — TRAP, conditional on OF
          d_len=pfx_len+4'd1;
          // user mode: prior loud-HALT (d_unknown) preserved for bit-identity.
          if (sys_mode) begin d_int=1'b1; d_int_vec=8'd4; d_int_cond_of=1'b1; end
          else d_unknown=1'b1;
        end
        8'hCF: begin // IRET — pop EIP/CS/EFLAGS (near, same-privilege)
          d_len=pfx_len+4'd1;
          if (sys_mode) d_iret=1'b1; else d_unknown=1'b1;
        end

        // -------------------------------------------------------------------
        // M2S.1 system-mode instructions (real-mode boot + real->PM transition).
        // -------------------------------------------------------------------
        8'hEA: begin // far JMP ptr16:off  (EA off16/32 sel16)
          // operand-size selects the offset width: 16-bit by default (real mode
          // EA off16 sel16, len=5) or 32-bit under 0x66 (66 EA off32 sel16,
          // len=7 incl the 66 prefix — pfx_len counts the 66). The bootstrap uses
          // BOTH: the 16-bit reset stub (EA off16 sel16) and the 66 ljmp ptr16:32.
          d_sysop=SYS_LJMP;
          if (eff_opsize) begin
            d_ljmp_off={16'd0, ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+4], ibuf[pfx_len+3]};
            d_len=pfx_len+4'd5;
          end else begin
            d_ljmp_off={ibuf[pfx_len+4], ibuf[pfx_len+3], ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+6], ibuf[pfx_len+5]};
            d_len=pfx_len+4'd7;
          end
        end
        8'h9A: begin // far CALL ptr16:16 (9A off16 sel16) / ptr16:32 under 0x66.
          // M9.5: push CS then the return IP (S_LCALL), then real-mode CS load
          // (base=sel<<4) + EIP=off. Operand size selects the offset/push width.
          d_sysop=SYS_LCALL;
          if (eff_opsize) begin
            d_ljmp_off={16'd0, ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+4], ibuf[pfx_len+3]};
            d_w=3'd2; d_len=pfx_len+4'd5;
          end else begin
            d_ljmp_off={ibuf[pfx_len+4], ibuf[pfx_len+3], ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+6], ibuf[pfx_len+5]};
            d_w=3'd4; d_len=pfx_len+4'd7;
          end
        end
        8'hF4: begin // HLT — stop retiring (a clean spin in the bare-metal test)
          d_halt=1'b1; d_len=pfx_len+4'd1;
        end

        // -------------------------------------------------------------------
        // M7.3b PORT I/O — IN/OUT (docs/m7-lockstep-spec.md M7.3). The decode is
        // UNCONDITIONAL (not gated on sys/cosim) so the length is always right;
        // the FSM (S_DECODE) decides what to DO: in --win95 co-sim mode an IN
        // takes its value off the io bus + an OUT drives the port out; OUTSIDE
        // co-sim the only legal use is the isa-debug-exit `out 0xf4` terminator
        // (preserved — HALT, no extra retire), and any other IN/OUT HALTs loudly.
        // Width: AL forms (E4/E6/EC/EE) = byte; eAX forms = eff-opsize (word in
        // real mode, dword in 32-bit). Port: imm8 (E4-E7) or DX (EC-EF).
        // -------------------------------------------------------------------
        8'hE4, 8'hE5: begin   // IN AL/eAX, imm8
          d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b1; d_io_port_imm=ibuf[pfx_len+1];
          d_io_w = (op0==8'hE4) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd2;
        end
        8'hE6, 8'hE7: begin   // OUT imm8, AL/eAX
          d_io=1'b1; d_io_write=1'b1; d_io_imm=1'b1; d_io_port_imm=ibuf[pfx_len+1];
          d_io_w = (op0==8'hE6) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd2;
        end
        8'hEC, 8'hED: begin   // IN AL/eAX, DX
          d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b0;
          d_io_w = (op0==8'hEC) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd1;
        end
        8'hEE, 8'hEF: begin   // OUT DX, AL/eAX
          d_io=1'b1; d_io_write=1'b1; d_io_imm=1'b0;
          d_io_w = (op0==8'hEE) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd1;
        end

        // -------------------------------------------------------------------
        // x87 FPU escapes D8..DF (single-byte opcode + ModR/M). m_idx already
        // points at the ModR/M byte; mod==11 = register form (length 2),
        // mod!=11 = memory form (length = m_idx + mfl(...)). We classify into a
        // fxop and supply addressing; the FPU exec path consumes them.
        // m3-fpu-spec.md: Tier-1/2 ops are routed; deferred/Tier-3 ops set
        // d_unknown so the core HALTs loudly (never mis-executes).
        // -------------------------------------------------------------------
        8'b1101_1???: begin
          d_is_x87=1'b1;
          d_f_sti = modrm_rm;
          // default length: register form 2, memory form variable
          if (modrm_mod==2'b11) d_len = m_idx + 4'd1;      // opcode + modrm
          else                  d_len = m_idx + mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          unique case (op0)
            // ----- D8: arithmetic ST0 op= m32 / ST0 op= ST(i) --------------
            8'hD8: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin
                    d_fxop=FX_AR_M32; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd4;
                  end
                  3'd2: begin d_fxop=FX_FCOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  default: begin d_fxop=FX_FCOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                endcase
              end else begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_ST0_STI; d_f_aluop=modrm_reg; end
                  3'd2: d_fxop=FX_FCOM_STI;
                  default: begin d_fxop=FX_FCOM_STI; d_f_pop=1'b1; end
                endcase
              end
            end
            // ----- D9: loads/const/stack/sign/control -----------------------
            8'hD9: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FLD_M32;  d_f_mem_read=1'b1;  d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FST_M32;  d_f_mem_write=1'b1; d_f_mbytes=4'd4; end
                  3'd3: begin d_fxop=FX_FST_M32;  d_f_mem_write=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                  // REVIEW1_Aug2 M-04: with a 66h prefix these move a 14-byte object,
                  // not a 28-byte one. The sequencer wrote the 28-byte image REGARDLESS,
                  // corrupting 14 bytes past the guest's object; the form was then made
                  // a LOUD unknown so the omission was at least visible. It is now
                  // IMPLEMENTED: d_f_mbytes carries the width to the FSM (nothing else
                  // consults it outside S_FLOAD/S_FSTORE, which these never enter), the
                  // beat COUNT is unchanged at seven, and only the stride, the strobe
                  // and the field layout differ -- see fenv_image16 in core.sv.
                  3'd4: begin d_fxop=FX_FLDENV;   // env load  (S_FENV_LD owns the beats)
                        d_f_mbytes = eff_opsize ? 4'd2 : 4'd4; end
                  3'd5: begin d_fxop=FX_FLDCW;    d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd6: begin d_fxop=FX_FNSTENV;  // env store (S_FENV_ST owns the beats)
                        d_f_mbytes = eff_opsize ? 4'd2 : 4'd4; end
                  3'd7: begin d_fxop=FX_FNSTCW;   d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique casez (mrm)
                  8'b1100_0???: d_fxop=FX_FLD_STI;            // D9 C0+i FLD st(i)
                  8'b1100_1???: d_fxop=FX_FXCH;               // D9 C8+i FXCH
                  8'hD0:        d_fxop=FX_FNOP;                // D9 D0   FNOP
                  8'hE0:        d_fxop=FX_FCHS;                // D9 E0
                  8'hE1:        d_fxop=FX_FABS;                // D9 E1
                  8'hE4:        d_fxop=FX_FTST;                // D9 E4
                  8'hE5:        d_fxop=FX_FXAM;                // D9 E5
                  8'hE8:        begin d_fxop=FX_FLDCONST; d_f_const=3'd0; end  // FLD1
                  8'hE9:        begin d_fxop=FX_FLDCONST; d_f_const=3'd1; end  // FLDL2T
                  8'hEA:        begin d_fxop=FX_FLDCONST; d_f_const=3'd2; end  // FLDL2E
                  8'hEB:        begin d_fxop=FX_FLDCONST; d_f_const=3'd3; end  // FLDPI
                  8'hEC:        begin d_fxop=FX_FLDCONST; d_f_const=3'd4; end  // FLDLG2
                  8'hED:        begin d_fxop=FX_FLDCONST; d_f_const=3'd5; end  // FLDLN2
                  8'hEE:        begin d_fxop=FX_FLDCONST; d_f_const=3'd6; end  // FLDZ
                  8'hF6:        d_fxop=FX_FDECSTP;            // D9 F6
                  8'hF7:        d_fxop=FX_FINCSTP;            // D9 F7
                  8'hFA:        d_fxop=FX_FSQRT;              // D9 FA FSQRT
                  // NOT transcendental, NOT gated — libm floor/ceil/rint, ldexp:
                  8'hFC:        d_fxop=FX_FRNDINT;            // D9 FC FRNDINT
                  8'hFD:        d_fxop=FX_FSCALE;             // D9 FD FSCALE (ST0 *= 2^trunc(ST1))
`ifdef VEN_FPREM
                  8'hF8:        d_fxop=FX_FPREM;              // D9 F8 FPREM  (trunc-Q partial remainder, fpu_fprem)
                  8'hF5:        d_fxop=FX_FPREM1;             // D9 F5 FPREM1 (round-nearest-Q IEEE remainder)
`endif
                  // D9 F8 FPREM (without VEN_FPREM) stays DEFERRED: a true remainder
                  // must be EXACT (ST0-Q*ST1), but fx_mul rounds — it needs the
                  // dedicated exact-remainder engine (fpu_fprem). Left as d_unknown
                  // (loud HALT) when the engine is not built — never mis-executed.
`ifdef VEN_TRANSCENDENTAL
                  8'hF0:        d_fxop=FX_F2XM1;              // D9 F0 F2XM1 (#11)
                  8'hF1:        d_fxop=FX_FYL2X;              // D9 F1 FYL2X (#11)
                  8'hF3:        d_fxop=FX_FPATAN;             // D9 F3 FPATAN (#11)
                  8'hF9:        d_fxop=FX_FYL2XP1;            // D9 F9 FYL2XP1 (#11)
                  8'hFE:        d_fxop=FX_FSIN;               // D9 FE FSIN (#11)
                  8'hFF:        d_fxop=FX_FCOS;               // D9 FF FCOS (#11)
                  8'hFB:        d_fxop=FX_FSINCOS;            // D9 FB FSINCOS (#11)
                  8'hF2:        d_fxop=FX_FPTAN;              // D9 F2 FPTAN (#11)
`elsif VEN_FPTRAP
                  // No HW transcendental engine (too big for xck26) — PS-trap FPATAN,
                  // Quake's ONLY transcendental. D9 F3 -> FX_FPATAN -> S_FPTRAP_WAIT.
                  8'hF3:        d_fxop=FX_FPATAN;             // D9 F3 FPATAN (PS-trap)
`endif
                  default:      d_unknown=1'b1;  // transcendentals/F2XM1/etc deferred
                endcase
              end
            end
            // ----- DA: FIADD..m32, FICOM m32, FUCOMPP -----------------------
            8'hDA: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_I32; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FICOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  default: begin d_fxop=FX_FICOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                endcase
              end else begin
                if (mrm==8'hE9) begin d_fxop=FX_FUCOMPP; d_f_pop2=1'b1; end
                else d_unknown=1'b1;   // FCMOVcc deferred (not P5-era anyway)
              end
            end
            // ----- DB: FILD m32, FISTP m32, FNINIT/FNCLEX, FLD m80, FSTP m80 -
            8'hDB: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FILD_M32; d_f_mem_read=1'b1;  d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FIST_M32; d_f_mem_write=1'b1; d_f_mbytes=4'd4; end
                  3'd3: begin d_fxop=FX_FIST_M32; d_f_mem_write=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                  3'd5: begin d_fxop=FX_FLD_M80;  d_f_mem_read=1'b1;  d_f_mbytes=4'd10; end
                  3'd7: begin d_fxop=FX_FST_M80;  d_f_mem_write=1'b1; d_f_mbytes=4'd10; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique case (mrm)
                  8'hE2: d_fxop=FX_FNCLEX;
                  8'hE3: d_fxop=FX_FNINIT;
                  default: d_unknown=1'b1;  // FCMOVcc/FCOMI deferred
                endcase
              end
            end
            // ----- DC: arithmetic ST0 op= m64 / ST(i) op= ST0 ---------------
            8'hDC: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_M64; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd8; end
                  3'd2: begin d_fxop=FX_FCOM_M64; d_f_mem_read=1'b1; d_f_mbytes=4'd8; end
                  default: begin d_fxop=FX_FCOM_M64; d_f_mem_read=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                endcase
              end else begin
                unique case (modrm_reg)
                  // DC C0+i .. : ST(i)-destination forms. The x87 SUBR/SUB and
                  // DIVR/DIV senses are SWAPPED for the ST(i)-dest encoding vs
                  // the ST0-dest one (classic x87 "reverse" gotcha): reg=4 means
                  // FSUBR(ST(i)=ST0-ST(i)), 5=FSUB(ST(i)-ST0), 6=FDIVR, 7=FDIV.
                  // We flip aluop bit0 for the {sub,div} group so f_arith (a=ST(i),
                  // b=ST0) computes the right direction.
                  3'd0,3'd1: begin d_fxop=FX_AR_STI_ST0; d_f_aluop=modrm_reg; end
                  3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_STI_ST0; d_f_aluop={modrm_reg[2:1], ~modrm_reg[0]}; end
                  default: d_unknown=1'b1;
                endcase
              end
            end
            // ----- DD: FLD/FST m64, FST st(i), FFREE, FUCOM, FNSTSW m16 -----
            8'hDD: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FLD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd2: begin d_fxop=FX_FST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; end
                  3'd3: begin d_fxop=FX_FST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  3'd4: begin d_fxop=FX_FRSTOR;  // 108-byte state load + reg reload
                        // REVIEW1_Aug2 M-04: the 94-byte form. Same 640 bits of ST
                        // register data as the 108-byte one, delivered 40 words instead
                        // of 20 dwords -- 47 beats total, which is why f_seq_step went
                        // to 6 bits and env_tmp to 47 entries.
                        d_f_mbytes = eff_opsize ? 4'd2 : 4'd4; end
                  3'd6: begin d_fxop=FX_FNSAVE;  // 108-byte state store + FNINIT reinit
                        // REVIEW1_Aug2 M-04: the 94-byte form. Same 640 bits of ST
                        // register data as the 108-byte one, delivered 40 words instead
                        // of 20 dwords -- 47 beats total, which is why f_seq_step went
                        // to 6 bits and env_tmp to 47 entries.
                        d_f_mbytes = eff_opsize ? 4'd2 : 4'd4; end
                  3'd7: begin d_fxop=FX_FNSTSW_M; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique casez (mrm)
                  8'b1100_0???: d_fxop=FX_FFREE;             // DD C0+i FFREE
                  8'b1101_0???: d_fxop=FX_FST_STI;           // DD D0+i FST st(i)
                  8'b1101_1???: begin d_fxop=FX_FST_STI; d_f_pop=1'b1; end // DD D8+i FSTP st(i)
                  8'b1110_0???: d_fxop=FX_FUCOM_STI;         // DD E0+i FUCOM
                  8'b1110_1???: begin d_fxop=FX_FUCOM_STI; d_f_pop=1'b1; end // DD E8+i FUCOMP
                  default:      d_unknown=1'b1;
                endcase
              end
            end
            // ----- DE: arithmetic-and-pop ST(i) op= ST0, FCOMPP -------------
            8'hDE: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_I16; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd2; end
                  3'd2: begin d_fxop=FX_FICOM_M16; d_f_mem_read=1'b1; d_f_mbytes=4'd2; end
                  default: begin d_fxop=FX_FICOM_M16; d_f_mem_read=1'b1; d_f_mbytes=4'd2; d_f_pop=1'b1; end
                endcase
              end else begin
                if (mrm==8'hD9) begin d_fxop=FX_FCOMPP; d_f_pop2=1'b1; end
                else begin
                  unique case (modrm_reg)
                    // DE C0+i ..: ST(i)-dest + pop. Same SUBR/SUB, DIVR/DIV swap
                    // as the DC-reg group (see note above).
                    3'd0,3'd1: begin d_fxop=FX_AR_STI_ST0; d_f_aluop=modrm_reg; d_f_pop=1'b1; end
                    3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_STI_ST0; d_f_aluop={modrm_reg[2:1], ~modrm_reg[0]}; d_f_pop=1'b1; end
                    default: d_unknown=1'b1;
                  endcase
                end
              end
            end
            // ----- DF: FILD m16/m64, FISTP m16/m64, FNSTSW AX --------------
            8'hDF: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FILD_M16; d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd2: begin d_fxop=FX_FIST_M16; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  3'd3: begin d_fxop=FX_FIST_M16; d_f_mem_write=1'b1; d_f_mbytes=4'd2; d_f_pop=1'b1; end
                  3'd4: begin d_fxop=FX_FBLD;  d_f_mem_read=1'b1;  d_f_mbytes=4'd10; end          // FBLD m80 (packed BCD)
                  3'd5: begin d_fxop=FX_FILD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd6: begin d_fxop=FX_FBSTP; d_f_mem_write=1'b1; d_f_mbytes=4'd10; d_f_pop=1'b1; end // FBSTP m80 + pop
                  3'd7: begin d_fxop=FX_FIST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                if (mrm==8'hE0) d_fxop=FX_FNSTSW_AX;
                else d_unknown=1'b1;
              end
            end
            default: d_unknown=1'b1;
          endcase
          if (d_unknown) d_is_x87=1'b0;   // a deferred escape HALTs as unknown
        end

        default: begin d_len=pfx_len+4'd1; d_unknown=1'b1; end
      endcase
    end

    // Map an 8-bit HIGH-byte register operand (AH..BH, encoded index 4..7) to
    // its physical GPR (EAX..EBX = index 0..3). The high8 flag then selects bits
    // [15:8]. Low 8-bit regs (AL..BL, index 0..3) and 16/32-bit regs are
    // physical already. This keeps every reg_read/reg_merge site using
    // gpr[d_*_reg] directly.
    if (d_dst_high8) d_dst_reg = {1'b0, d_dst_reg[1:0]};
    if (d_src_high8) d_src_reg = {1'b0, d_src_reg[1:0]};

    // REVIEW2 C-09 (the #UD half): an illegal LOCK prefix must raise #UD. LOCK was
    // decoded and then reached only the F00F erratum check and a lint sink, so
    // `lock` on anything at all was silently accepted.
    //
    // LOCK architecturally requires a MEMORY destination operand. The rule applied
    // here is the unambiguous subset: a LOCK on an instruction with NO memory operand
    // at all is illegal, full stop. That covers `lock` on register-form RMWs -- which
    // is also the shape of the F00F erratum (locked CMPXCHG8B with a register
    // destination) -- and cannot false-positive.
    //
    // NOT covered: LOCK on an instruction that HAS a memory operand but is not one of
    // the permitted RMW opcodes (ADD/ADC/AND/BTC/BTR/BTS/CMPXCHG/CMPXCHG8B/DEC/INC/
    // NEG/NOT/OR/SBB/SUB/XOR/XADD/XCHG). Deciding that needs a per-arm `lock_ok` flag
    // on ~18 decode arms; guessing it from the existing d_* flags would either miss
    // cases or wrongly fault a legal locked RMW. Marked as remaining rather than
    // approximated -- a wrong #UD on a legal `lock add [mem],eax` would be far worse
    // than the missing check.
    //
    // Routed through d_unknown so it reuses H-11's #UD delivery. Ordering is already
    // correct in core_fetch_decode.svh: the F00F erratum arm is tested BEFORE the #UD
    // arm, so with errata_en[ERR_F00F] set the documented hang still wins.
    if (pfx_lock && !(d_mem_read || d_mem_write)) d_unknown = 1'b1;
    // REVIEW1_Aug2 C-10: a LOCK on a memory RMW is the case that must reach the bus.
    d_lock = pfx_lock && (d_mem_read || d_mem_write);

    // ---- REVIEW1_Aug2 M-01: LOCK is legal only on specific opcodes ---------------
    // The rule above rejects LOCK when there is no memory operand at all. It does not
    // reject LOCK on an opcode that HAS one but is not lockable -- `lock mov [mem],eax`
    // executed. The old comment said deciding this needed a per-arm flag on ~18 decode
    // arms; it does not. Lockability is a property of the OPCODE, so it is a pure
    // function of the opcode bytes and ModR/M.reg, written here in one place.
    //
    // ALLOW-LIST, deliberately, and FAIL-OPEN: an opcode not recognised below is left
    // alone rather than faulted. A wrong #UD on a legal `lock add [mem],eax` would be
    // far worse than a missed check, so anything uncertain stays permitted. The list is
    // the SDM's: ADD ADC AND BTC BTR BTS CMPXCHG CMPXCHG8B DEC INC NEG NOT OR SBB SUB
    // XOR XADD XCHG -- and only in their MEMORY-DESTINATION forms.
    begin
      logic lock_legal;
      lock_legal = 1'b0;
      if (two_byte) begin
        unique case (ibuf[pfx_len+1])
          8'hB0, 8'hB1: lock_legal = 1'b1;                 // CMPXCHG r/m, r
          8'hC0, 8'hC1: lock_legal = 1'b1;                 // XADD    r/m, r
          8'hB3, 8'hBB, 8'hAB: lock_legal = 1'b1;          // BTR / BTC / BTS r/m, r
          8'hBA: lock_legal = (modrm_reg >= 3'd5);         // BTS/BTR/BTC imm8 (not BT=4)
          8'hC7: lock_legal = (modrm_reg == 3'd1);         // CMPXCHG8B m64
          default: lock_legal = 1'b0;
        endcase
      end else begin
        unique case (op0)
          // The r/m,reg (memory-DESTINATION) forms of the group-1 ALU ops. The
          // reg,r/m forms (02/03, 0A/0B, ...) read memory and write a REGISTER, so
          // LOCK is illegal on them -- that asymmetry is the point of listing the
          // even/odd pairs explicitly rather than masking.
          8'h00, 8'h01, 8'h08, 8'h09, 8'h10, 8'h11, 8'h18, 8'h19,
          8'h20, 8'h21, 8'h28, 8'h29, 8'h30, 8'h31: lock_legal = 1'b1;
          8'h80, 8'h81, 8'h83: lock_legal = (modrm_reg != 3'd7);   // group 1, not CMP
          8'h86, 8'h87: lock_legal = 1'b1;                          // XCHG r/m, r
          8'hF6, 8'hF7: lock_legal = (modrm_reg == 3'd2)            // NOT
                                  || (modrm_reg == 3'd3);           // NEG
          8'hFE:        lock_legal = (modrm_reg <= 3'd1);            // INC/DEC r/m8
          8'hFF:        lock_legal = (modrm_reg <= 3'd1);            // INC/DEC r/m
          default:      lock_legal = 1'b0;
        endcase
      end
      // Only fault when there IS a memory operand -- the no-memory case is already
      // handled above, and doubling it up would just obscure which rule fired.
      if (pfx_lock && (d_mem_read || d_mem_write) && !lock_legal) d_unknown = 1'b1;
    end
  end

endmodule : decode_stages
