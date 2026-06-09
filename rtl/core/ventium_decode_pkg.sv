// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/ventium_decode_pkg.sv — decode TYPES + pure decode helpers, extracted
// verbatim from intcore.sv (R1 modularization, docs/rtl-refactor-plan.md).
//
// Holds the op-class enum (kind_e), the micro-sequencer enums (smk_e stack /
// st_e string / ctk_e control), the x87 decode enum (fxop_e), the fast-path
// decoded-uop struct (fpd_t) + its FP-kind selectors (FK_*), and the pure
// length/prefix/condition helpers mfl()/is_prefix()/cond_true(). These are
// PURE types + functions (no module state), so moving them here and using
// them in place is bit-identical.

package ventium_decode_pkg;

  // op classes
  typedef enum logic [4:0] {
    K_ALU, K_SHIFT, K_SHLDRD, K_MULDIV, K_IMUL2, K_EXT, K_SETCC,
    K_BITTEST, K_BITSCAN, K_XCHG, K_BSWAP, K_CONV, K_STKMISC, K_STR, K_CTRL,
    K_CMPXCHG,
    K_CPUID   // M7.3c: CPUID (0F A2) — writes eax/ebx/ecx/edx from a fixed leaf table
  } kind_e;

  typedef enum logic [2:0] { SM_PUSHA, SM_POPA, SM_PUSHF, SM_POPF, SM_LAHF, SM_SAHF, SM_LEAVE } smk_e;
  typedef enum logic [2:0] { ST_MOVS, ST_STOS, ST_LODS, ST_SCAS, ST_CMPS,
                             ST_INS  // M7.3c: INS (6C/6D) — IN per element -> [EDI]
                           } st_e;  // 6 values -> still fits [2:0]
  typedef enum logic [3:0] {
    CT_CALLREL, CT_RETN, CT_RETN_IMM, CT_CALLIND, CT_JMPIND,
    CT_LOOP, CT_LOOPE, CT_LOOPNE, CT_JECXZ
  } ctk_e;

  // ---- x87 decode (M3) ------------------------------------------------------
  // x87 sub-op encoding for the FPU execution path. The decoder classifies each
  // escape (D8..DF + ModR/M) into one of these and supplies the addressing
  // (d_f_mem_read/write + d_f_msize) and operand index (d_f_sti) it needs.
  typedef enum logic [5:0] {
    FX_NONE,
    // loads / pushes
    FX_FLD_M32, FX_FLD_M64, FX_FLD_M80, FX_FLD_STI,
    FX_FILD_M16, FX_FILD_M32, FX_FILD_M64,
    FX_FLDCONST,             // d_f_const selects which ROM constant
    // stores
    FX_FST_M32, FX_FST_M64, FX_FST_M80, FX_FST_STI,    // pop variants via d_f_pop
    FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
    FX_FNSTCW, FX_FNSTSW_M, FX_FNSTSW_AX, FX_FLDCW,
    // stack management
    FX_FXCH, FX_FFREE, FX_FINCSTP, FX_FDECSTP, FX_FNOP, FX_FNINIT, FX_FNCLEX, FX_FWAIT,
    // sign / abs
    FX_FABS, FX_FCHS,
    // compares / classify
    FX_FCOM_M32, FX_FCOM_M64, FX_FCOM_STI, FX_FUCOM_STI,
    FX_FCOMPP, FX_FUCOMPP, FX_FTST, FX_FXAM,
    FX_FICOM_M16, FX_FICOM_M32,
    // arithmetic (d_f_aluop selects add/sub/subr/mul/div/divr; flavor via fields)
    FX_AR_ST0_STI,           // ST0 op= ST(i)
    FX_AR_STI_ST0,           // ST(i) op= ST0
    FX_AR_M32, FX_AR_M64,    // ST0 op= mem float
    FX_AR_I16, FX_AR_I32,    // ST0 op= mem int (FIADD..)
    FX_FSQRT,
    // M10: packed-BCD load (FBLD, DF /4) / round-store-and-pop (FBSTP, DF /6)
    FX_FBLD, FX_FBSTP,
    // M11: x87 environment / state save & restore
    FX_FNSTENV, FX_FLDENV, FX_FNSAVE, FX_FRSTOR,
    // M11 #11: x87 transcendentals (D9 group) — iterative engines, gated behind
    // +VEN_TRANSCENDENTAL (the decode that PRODUCES these is gated; the default
    // build keeps treating D9 F0/F1/F2/F3/F9/FB/FE/FF as d_unknown -> HALT, so the
    // 77/77 corpus stays byte-identical). Appended at the END so every existing
    // fxop's enum encoding is unchanged.
    FX_F2XM1
  } fxop_e;

  // ===========================================================================
  // ModR/M field length (instruction length contribution of ModR/M+SIB+disp).
  // ===========================================================================
  function automatic logic [3:0] mfl(input logic [1:0] mod, input logic [2:0] rm,
                                     input logic sib, input logic [2:0] base);
    logic [3:0] disp;
    begin
      if (mod==2'b01)                          disp=4'd1;
      else if (mod==2'b10)                     disp=4'd4;
      else if (mod==2'b00 && rm==3'b101)       disp=4'd4;
      else if (mod==2'b00 && sib && base==3'b101) disp=4'd4;
      else                                     disp=4'd0;
      return 4'd1 + (sib?4'd1:4'd0) + disp;
    end
  endfunction

  // ===========================================================================
  // Prefix detection.
  // ===========================================================================
  function automatic logic is_prefix(input logic [7:0] b);
    is_prefix = (b==8'h66)||(b==8'h67)||(b==8'h2E)||(b==8'h36)||(b==8'h3E)||
                (b==8'h26)||(b==8'h64)||(b==8'h65)||(b==8'hF0)||(b==8'hF2)||(b==8'hF3);
  endfunction

  // ===========================================================================
  // Jcc condition evaluation (tttn against EFLAGS).
  // ===========================================================================
  function automatic logic cond_true(input logic [3:0] tttn, input logic [31:0] fl);
    logic cf,pf,zf,sf,of,res;
    begin
      cf=fl[0]; pf=fl[2]; zf=fl[6]; sf=fl[7]; of=fl[11];
      unique case (tttn[3:1])
        3'b000: res=of; 3'b001: res=cf; 3'b010: res=zf; 3'b011: res=cf|zf;
        3'b100: res=sf; 3'b101: res=pf; 3'b110: res=(sf^of); 3'b111: res=(zf|(sf^of));
        default: res=1'b0;
      endcase
      return tttn[0] ? ~res : res;
    end
  endfunction

  // ===========================================================================
  // Fast-path decoded-uop struct (M4/M5 dual-issue pipe). A packed struct so two
  // can be evaluated in one always_comb. See intcore.sv fp_decode for producer.
  // ===========================================================================
  typedef struct packed {
    logic        simple;
    logic [3:0]  len;
    logic [4:0]  alu_op;
    logic [2:0]  dst;
    logic [2:0]  src;
    logic        use_imm;
    logic [31:0] imm;
    logic        wflags;
    logic        wreg;
    logic        is_lea;
    logic        is_load;
    logic [2:0]  base;
    logic        is_nop;
    logic        is_shift;
    logic [2:0]  shrot;
    logic [4:0]  shimm;
    logic        is_branch;
    logic        br_cond;
    logic        br_taken;
    logic [3:0]  cc;            // condition code (Jcc low nibble) for fwd re-eval
    logic [31:0] rel;
    logic [7:0]  reads;
    logic [7:0]  writes;
    logic [7:0]  addr_mask;
    logic        pairs_first;
    logic        pairs_second;
    logic        disp_imm;
    // ---- M6 Erratum 59 (cycle-mode only): MOV moffs short forms A2/A3 --------
    // The absolute-displacement store forms (opcodes 0xA2 MOV moffs8,AL and 0xA3
    // MOV moffs,eAX). They ARE UV-pairable per the SDM, but the P5 instruction
    // unit falsely fails to pair them when the NEXT instruction references EAX.
    // is_moffs flags the U-member so the pairing logic can reproduce that defect
    // behind errata_en[ERR_MOFFS]. Cycle-mode only (func mode keeps moffs on the
    // proven slow FSM) -> no functional risk; the store value is not traced.
    logic        is_moffs;     // A2/A3 absolute-displacement MOV store (cycle-mode)
    // ---- M5 x87/FP cycle-accuracy fast-path fields (cycle-mode only) --------
    // A small whitelist of register-form x87 ops is recognised here so the FP
    // *cycle* model (latency/throughput, the p5model fp_role scoreboard) is
    // emergent from the dual-issue pipe rather than the M4 slow-FSM serialize.
    // Functional execution reuses the SAME exact helpers (fconst/f_eval/...), so
    // arch state is bit-identical to the slow path. is_fp is asserted ONLY in
    // cycle_mode (func mode keeps FP on the proven slow FSM -> no regression).
    logic        is_fp;       // fast-path x87 op (cycle-mode whitelist)
    logic [2:0]  fp_kind;     // FK_* below
    logic [2:0]  fp_aluop;    // x87 group (add/sub/mul/div/...) for FK_ARITH
    logic [2:0]  fp_sti;      // st(i) index operand
    logic [2:0]  fp_role;     // p5model fp_role: 0 none,1 producer,2 consumer,3 rmw
    logic [6:0]  fp_lat;      // FP result latency (cycles) for the scoreboard
    logic [6:0]  fp_occ;      // FP pipe OCCUPANCY (cycles the in-order pipe is held)
    logic        is_fxch_free;// GAP2/VEN_FXCH_FREE: a FREE FXCH (occ 0) — folds into
                              // the preceding push's commit clock (no own cycle)
  } fpd_t;

  // FP fast-path op kinds (the cycle-mode x87 whitelist).
  localparam logic [2:0] FK_NONE   = 3'd0;
  localparam logic [2:0] FK_FLDC   = 3'd1;   // FLD const (e.g. FLD1) — push
  localparam logic [2:0] FK_ARITH  = 3'd2;   // ST0 op= ST(i) (reg form)
  localparam logic [2:0] FK_FSTP0  = 3'd3;   // FSTP %st(0) — pop (discard)
  localparam logic [2:0] FK_FLDSTI = 3'd4;   // FLD ST(i) — push copy
  localparam logic [2:0] FK_FXCH   = 3'd5;   // FXCH ST(i)

endpackage : ventium_decode_pkg
