`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
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
    K_CPUID,  // M7.3c: CPUID (0F A2) — writes eax/ebx/ecx/edx from a fixed leaf table
    K_RDTSC,  // F3: RDTSC (0F 31) — writes edx:eax from the 64-bit time-stamp counter
    K_XADD,   // XADD r/m,r (0F C0/C1): temp=dst; dst=dst+src (ADD flags); src=temp.
    K_BOUND,  // BOUND r,m (0x62): #BR if index < [mem] (lower) or > [mem+w] (upper)
    K_CX8B    // CMPXCHG8B m64 (0F C7 /1): EDX:EAX vs [m64]; eq -> [m64]=ECX:EBX, ZF=1
              // Appended at the END so every existing kind_e encoding is unchanged.
  } kind_e;

  // SM_ENTER appended at the END (encoding 7, still fits [2:0]) so SM_PUSHA..
  // SM_LEAVE keep their values. ENTER imm16,0 (level-0) pushes EBP then sets the
  // new frame — a single store + register update, modelled like SM_PUSHF.
  typedef enum logic [2:0] { SM_PUSHA, SM_POPA, SM_PUSHF, SM_POPF, SM_LAHF, SM_SAHF,
                             SM_LEAVE, SM_ENTER } smk_e;
  typedef enum logic [2:0] { ST_MOVS, ST_STOS, ST_LODS, ST_SCAS, ST_CMPS,
                             ST_INS, // M7.3c: INS (6C/6D) — IN per element -> [EDI]
                             ST_OUTS // Win95 disk-write: OUTS (6E/6F) — [SI] element -> OUT port DX
                           } st_e;  // 7 values -> still fits [2:0]
  typedef enum logic [3:0] {
    CT_CALLREL, CT_RETN, CT_RETN_IMM, CT_CALLIND, CT_JMPIND,
    CT_LOOP, CT_LOOPE, CT_LOOPNE, CT_JECXZ
  } ctk_e;

  // ---- x87 decode (M3) ------------------------------------------------------
  // x87 sub-op encoding for the FPU execution path. The decoder classifies each
  // escape (D8..DF + ModR/M) into one of these and supplies the addressing
  // (d_f_mem_read/write + d_f_msize) and operand index (d_f_sti) it needs.
  typedef enum logic [6:0] {   // 7-bit: >64 fxops (FX_FPREM1 was the 65th, wrapped [5:0])
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
    FX_F2XM1, FX_FPATAN, FX_FYL2X, FX_FYL2XP1, FX_FSIN, FX_FCOS, FX_FSINCOS, FX_FPTAN,
    // D9 reg-form extended ops (NOT transcendental, NOT ifdef-gated): used by libm
    // floor/ceil/rint (FRNDINT), ldexp/scalbn (FSCALE), fmod (FPREM). Quake's
    // FloorDivMod + float math hit these on the render path. Appended at the END so
    // every existing fxop's enum encoding is unchanged.
    FX_FRNDINT, FX_FSCALE, FX_FPREM, FX_FPREM1
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
    // A fast-path data-memory operation. is_load is the MOV r32,[mem] subset
    // that writes mem_rdata directly to a GPR; is_store is the MOV
    // [mem],r32 subset. is_mem also covers read-only ALU operands (currently
    // CMP) which reuse the checked read request but feed the U ALU.
    logic        is_mem;
    logic        is_store;
    // Implicit 32-bit stack access (PUSH/POP register form).  This must not
    // use the generic ModR/M base+index AGU: it selects SS and derives its
    // offset from ESP with PUSH's pre-decrement / POP's post-increment rules.
    // The core keeps the update behind the normal checked memory packet so a
    // delayed access, page walk, fragment, or fault remains restartable.
    logic        is_stack;
    // Direct ModR/M disp32 addressing has no GPR base.  Keeping that fact as a
    // decoded bit is essential: using an arbitrary architectural register as a
    // stand-in would turn a literal address into a data-dependent address.
    logic        mem_base_en;
    // The ModR/M/SIB default segment is SS rather than DS.  This bit is set
    // only for the audited 32-bit EBP/ESP-base forms; overrides remain on the
    // slow decoder path.
    logic        mem_ss;
    // For a memory ALU operand, selects memory as the left (r/m) operand rather
    // than the right (r/m) operand. Meaningful only for a non-store, non-load
    // memory ALU operand.
    logic        mem_lhs;
    logic [2:0]  base;
    // The audited fast-load subset uses only 32-bit DS-default effective
    // addresses.  mem_index_en distinguishes a SIB index field of ESP, which
    // architecturally means "no index", from a real ESP register input.
    logic [2:0]  mem_index;
    logic [1:0]  mem_scale;
    logic        mem_index_en;
    logic [31:0] mem_disp;     // MOV r32,[base+index*scale+disp] displacement
    logic        is_nop;
`ifdef VEN_FAST_XCHG_R
    // One-byte XCHG eAX,r: two GPR destinations, U-only and two clocks.
    logic        is_xchg_r;
`endif
    logic        is_shift;
    // D3 /4../7 register shifts take their count from CL.  They are U-only
    // (P5 NP class) but share the exact same 32-bit shifter and flag rules as
    // C1/D1.  The bit keeps a literal imm8 count distinct from a live ECX read.
    logic        shift_cl;
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
    // ---- M6 Erratum 59: MOV moffs short forms A2/A3 -------------------------
    // The absolute-displacement store forms (opcodes 0xA2 MOV moffs8,AL and 0xA3
    // MOV moffs,eAX) are pairable in the clean model, but a P5 can falsely fail
    // to pair them when the NEXT instruction references EAX.  is_moffs marks a
    // real packetized A3 store when VEN_FAST_MOFFS_STORE admits it; the pairing
    // logic consumes the mark only on a cycle-mode U/V issue.  A2 remains on the
    // width-aware slow path until it has an independent byte-store audit.
    logic        is_moffs;     // A3 absolute-displacement dword MOV store
    // ---- task #56 step A: OPERAND-SIZE support for the fast path ------------
    // The fast-path datapath has never had a width concept -- every arm is hardwired
    // 32-bit, which is why core_fastpath.svh:288 must send ALL sys_mode instructions
    // to the slow FSM (the slow path carries d_w on every arm, decode_stages.sv:355).
    // w16=1 means "this instruction operates on 16 bits": the destination's UPPER 16
    // BITS MUST BE PRESERVED and flags computed on the 16-bit result.
    // STEP A lands the plumbing with w16 hardwired 0 everywhere, so behaviour is
    // bit-identical; decode.sv starts setting it in step B, once it can derive
    // eff_opsize (which needs prefix recognition it does not yet have).
    logic        w16;         // 1 = 16-bit operand size (upper half of dst preserved)
    // Byte operands are independent of CS.D / operand-size prefixes. src/dst
    // hold parent GPR indices (0..3 for AL..BH), never the encoded AH=4 etc.
    // Keep high-byte selection separate from address base/index registers.
    // No decoder arm sets these until byte memory and commit plumbing lands.
    logic        w8;
    logic        src_hi8;
    logic        dst_hi8;
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

  // Load-only descriptor flavors, not new ALU operations. All existing
  // arithmetic encodings occupy 0..19. No fpd_t/cache entry width increase.
  localparam logic [4:0] FP_LOAD_ZX8  = 5'd20;
  localparam logic [4:0] FP_LOAD_ZX16 = 5'd21;
  localparam logic [4:0] FP_LOAD_SX8  = 5'd22;
  localparam logic [4:0] FP_LOAD_SX16 = 5'd23;

  function automatic logic fp_is_ext_load(input fpd_t d);
`ifdef VEN_FAST_MEM_EXT
    return d.is_mem && d.is_load && !d.is_store &&
           (d.alu_op >= FP_LOAD_ZX8) && (d.alu_op <= FP_LOAD_SX16);
`else
    return 1'b0;
`endif
  endfunction

  // Request extent is independent of destination register merge width.
  // Generic byte/dword MOV/ALU/store behavior stays exactly as before.
  function automatic logic [2:0] fp_mem_source_width(input fpd_t d);
    if (fp_is_ext_load(d)) return d.alu_op[0] ? 3'd2 : 3'd1;
    return d.w8 ? 3'd1 : 3'd4;
  endfunction

  function automatic logic [3:0] fp_mem_read_strobe(input fpd_t d);
    case (fp_mem_source_width(d))
      3'd1: return 4'b0001;
      3'd2: return 4'b0011;
      default: return 4'b1111;
    endcase
  endfunction

  // Consumed only behind the established final checked packet ACK. Not an
  // AXI-beat converter; fragment merge/extraction remains upstream unchanged.
  function automatic logic [31:0] fp_load_result(input fpd_t d, input logic [31:0] raw);
    if (fp_is_ext_load(d)) begin
      case (d.alu_op)
        FP_LOAD_ZX8:  return {24'd0, raw[7:0]};
        FP_LOAD_ZX16: return {16'd0, raw[15:0]};
        FP_LOAD_SX8:  return {{24{raw[7]}}, raw[7:0]};
        FP_LOAD_SX16: return {{16{raw[15]}}, raw[15:0]};
        default: return raw;
      endcase
    end
    return raw;
  endfunction

  function automatic logic [2:0] fp_operand_width(input fpd_t d);
    return d.w8 ? 3'd1 : (d.w16 ? 3'd2 : 3'd4);
  endfunction

  // Checked-load -> V register-ALU bypass capability, not permission to issue
  // another memory request. Both slots wait for the captured packet's final
  // checked ack. Address consumers have separate datapaths. Exclude ALL WAW,
  // including ESP and disjoint bytes: V writeback merges against pre-U state.
  function automatic logic fp_load_use_forwardable(input fpd_t u, input fpd_t v);
`ifdef VEN_LOAD_USE_FORWARD
    return u.is_mem && u.is_load && u.wreg && !u.is_stack && !u.is_store
        && !u.is_fp && !u.is_lea && !u.is_shift && !u.is_branch
        && (u.writes == (8'h01 << u.dst))
        && !v.is_mem && !v.is_stack && !v.is_lea && !v.is_fp
        && !v.is_shift && !v.is_branch && !v.is_nop
        && (v.addr_mask == 8'd0) && ((v.writes & u.writes) == 8'd0);
`else
    return 1'b0;
`endif
  endfunction

  // Convert an x86 byte-register encoding to the parent architectural GPR.
  // Only DATA register fields use this: an EA base of ESP remains register 4.
  function automatic logic [2:0] fp_byte_parent(input logic [2:0] encoded);
    return {1'b0, encoded[1:0]};
  endfunction

  function automatic logic [31:0] fp_byte_read(input logic [31:0] value,
                                               input logic high_byte);
    return high_byte ? {24'd0, value[15:8]} : {24'd0, value[7:0]};
  endfunction

  function automatic logic [31:0] fp_byte_merge(input logic [31:0] previous,
                                                input logic [31:0] value,
                                                input logic high_byte);
    return high_byte ? {previous[31:16], value[7:0], previous[7:0]}
                     : {previous[31:8], value[7:0]};
  endfunction

  // FP fast-path op kinds (the cycle-mode x87 whitelist).
  localparam logic [2:0] FK_NONE   = 3'd0;
  // Shared-only memory admission reuses the otherwise non-executable zero
  // kind. is_fp distinguishes it from an unknown instruction. fp_sti[0]
  // carries m64 versus m32; it is NOT a stack index for this kind.
  // fp_role is then a memory flavor (0 arithmetic, 1 FLD, 2 FILD), not a
  // legacy FP scoreboard role. VEN_FP_MEM_LOADS adds only the load flavors.
  localparam logic [2:0] FK_MEM    = FK_NONE;
  localparam logic [2:0] FK_FLDC   = 3'd1;   // FLD const (e.g. FLD1) — push
  localparam logic [2:0] FK_ARITH  = 3'd2;   // ST0 op= ST(i) (reg form)
  localparam logic [2:0] FK_FSTP0  = 3'd3;   // FSTP %st(0) — pop (discard)
  localparam logic [2:0] FK_FLDSTI = 3'd4;   // FLD ST(i) — push copy
  localparam logic [2:0] FK_FXCH   = 3'd5;   // FXCH ST(i)
  // These two encodings are intentionally consumed only by the compact
  // VEN_FP_SHARED_DIRECT handoff.  Keeping them distinct from FK_ARITH avoids
  // teaching the legacy fast writeback an indexed-destination/pop datapath.
  // Without that shared-direct profile they are never emitted by decode.sv.
  localparam logic [2:0] FK_ARITH_STI     = 3'd6; // ST(i) op= ST0, no pop (DC)
  localparam logic [2:0] FK_ARITH_STI_POP = 3'd7; // ST(i) op= ST0, then pop (DE)

endpackage : ventium_decode_pkg
