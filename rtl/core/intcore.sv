// core/intcore.sv — M2 single-issue, in-order, multi-cycle functional integer
// core (PLAN.md §7, docs/m2-isa-spec.md). Extends the M1 core to user-mode
// integer ISA completeness, diff-clean vs QEMU user-mode.
//
// FSM skeleton (one instruction at a time, multi-cycle):
//   S_RESET  -> latch init_eip/init_esp/reset arch state
//   S_FETCH  -> read a 16-byte window at EIP (4 word reads)
//   S_DECODE -> combinational prefix+length+operand decode
//   S_LOAD   -> read a memory source / RMW dst / [ESI] or [EDI]
//   S_LOAD2  -> CMPS second memory operand ([EDI])
//   S_EXEC   -> compute result + EFLAGS; commit or hand off to a store/micro op
//   S_STORE  -> write a memory destination / push word
//   S_USEQ   -> micro-sequenced ops (PUSHA/POPA/POPF/string REP iterations)
//   S_HALT   -> int $0x80 or out-of-scope opcode: stop retiring
//
// Out-of-scope opcodes raise d_unknown and HALT loudly (no mis-execution).

module intcore
  import ventium_pkg::*;
  import fpu_x87_pkg::*;
#(
    parameter logic [31:0] EFLAGS_RESET = 32'h0000_0202, // bit1 reserved-1 + IF
    parameter logic [15:0] SEG_CS = 16'h0023,
    parameter logic [15:0] SEG_SS = 16'h002b,
    parameter logic [15:0] SEG_DS = 16'h002b,
    parameter logic [15:0] SEG_ES = 16'h002b,
    parameter logic [15:0] SEG_FS = 16'h0000,
    parameter logic [15:0] SEG_GS = 16'h002b
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack,

    output logic        retire_valid,
    output logic [31:0] retire_pc,
    output arch_state_t retire_state,

    // x87 post-commit architectural state (M3). Valid in the same cycle as
    // retire_valid. `retire_x87_touched` is 1 iff the retired instruction was an
    // x87 op (so ventium_top calls vtm_retire_x87 only then). st0..st7 are in
    // TOP-relative order (st0 = register at TOP), each canonical floatx80[79:0].
    // fstat already has TOP overlaid in bits[13:11]; ftag follows QEMU's
    // user-mode gdbstub convention (constant 0x0000).
    output logic        retire_x87_touched,
    output logic [15:0] retire_fctrl,
    output logic [15:0] retire_fstat,
    output logic [15:0] retire_ftag,
    output logic [79:0] retire_st0, retire_st1, retire_st2, retire_st3,
    output logic [79:0] retire_st4, retire_st5, retire_st6, retire_st7
);

  // ===========================================================================
  // Architectural state
  // ===========================================================================
  logic [31:0] eip;
  logic [31:0] eflags;
  logic [31:0] gpr [NUM_GPR];   // eax ecx edx ebx esp ebp esi edi

  // ===========================================================================
  // x87 FPU architectural state (M3)
  // ===========================================================================
  // Physical register file (8 x 80-bit) + TOP. st(i) = fpr[(ftop+i)&7]. Push
  // decrements TOP then writes; pop increments TOP (leaving the stale value, so
  // the trace's "empty" st-slots keep their last contents — matches QEMU).
  logic [79:0] fpr [8];
  logic [2:0]  ftop;
  logic [15:0] fctrl;            // control word; reset 0x037f
  // fstat holds the condition codes (C0/C1/C2/C3) + exception flags, with the
  // TOP field (bits[13:11]) kept ZERO internally; it is overlaid from `ftop` on
  // read (mirrors QEMU helper_fnstsw). fstat[15:11] are never written here.
  logic [15:0] fstat;
  // Architectural tag: 1=empty, 0=valid (drives FXAM's empty-detect + the FXAM
  // C1 sign bit). NOT reported in the trace (QEMU's gdbstub abridges ftag to 0).
  logic [7:0]  fptag;           // bit i = tag for fpr[i] (1=empty)
  logic        x87_touched_r;   // retired insn touched the FPU (drives DPI call)

  // ===========================================================================
  // FSM
  // ===========================================================================
  typedef enum logic [3:0] {
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_LOAD2, S_EXEC, S_STORE, S_USEQ, S_HALT,
    S_FLOAD, S_FEXEC, S_FSTORE
  } state_e;
  state_e state;

  localparam int IWORDS = 4;
  logic [7:0]  ibuf [16];
  logic [2:0]  fetch_word;

  // ALU op encoding (low 3 bits mirror the x86 ALU group order 0..7).
  localparam logic [4:0] ALU_ADD = 5'd0;
  localparam logic [4:0] ALU_OR  = 5'd1;
  localparam logic [4:0] ALU_ADC = 5'd2;
  localparam logic [4:0] ALU_SBB = 5'd3;
  localparam logic [4:0] ALU_AND = 5'd4;
  localparam logic [4:0] ALU_SUB = 5'd5;
  localparam logic [4:0] ALU_XOR = 5'd6;
  localparam logic [4:0] ALU_CMP = 5'd7;
  localparam logic [4:0] ALU_INC = 5'd8;
  localparam logic [4:0] ALU_DEC = 5'd9;
  localparam logic [4:0] ALU_TEST= 5'd10;
  localparam logic [4:0] ALU_MOV = 5'd11;
  localparam logic [4:0] ALU_NEG = 5'd12;
  localparam logic [4:0] ALU_NOT = 5'd13;

  // op classes
  typedef enum logic [4:0] {
    K_ALU, K_SHIFT, K_SHLDRD, K_MULDIV, K_IMUL2, K_EXT, K_SETCC,
    K_BITTEST, K_BITSCAN, K_XCHG, K_BSWAP, K_CONV, K_STKMISC, K_STR, K_CTRL
  } kind_e;

  typedef enum logic [2:0] { SM_PUSHA, SM_POPA, SM_PUSHF, SM_POPF, SM_LAHF, SM_SAHF, SM_LEAVE } smk_e;
  typedef enum logic [2:0] { ST_MOVS, ST_STOS, ST_LODS, ST_SCAS, ST_CMPS } st_e;
  typedef enum logic [3:0] {
    CT_CALLREL, CT_RETN, CT_RETN_IMM, CT_CALLIND, CT_JMPIND,
    CT_LOOP, CT_LOOPE, CT_LOOPNE, CT_JECXZ
  } ctk_e;

  // ===========================================================================
  // Decoder outputs (combinational)
  // ===========================================================================
  logic [3:0]  d_len;
  logic        d_halt;
  logic        d_unknown;
  logic        d_is_branch;
  logic        d_branch_taken;
  logic [31:0] d_rel;
  logic [4:0]  d_alu_op;
  logic        d_writes_reg;
  logic        d_writes_flags;
  logic        d_mem_read;
  logic        d_mem_write;
  logic        d_mem_dst;
  logic [2:0]  d_dst_reg;
  logic [2:0]  d_src_reg;
  logic [31:0] d_imm;
  logic        d_use_imm;
  logic        d_is_push;
  logic        d_is_pop;
  logic        d_is_lea;
  logic        d_is_mov;
  logic        d_is_nop;
  logic [31:0] d_ea;
  logic [2:0]  d_w;
  logic        d_dst_high8;
  logic        d_src_high8;
  kind_e       d_kind;
  logic [2:0]  d_shrot;
  logic        d_shift_cl;
  logic        d_shift_one;
  logic [4:0]  d_shift_imm;
  logic        d_shrd;
  logic [2:0]  d_md;
  logic        d_imul_3op;
  logic [31:0] d_imul_imm;
  logic        d_ext_signed;
  logic [2:0]  d_ext_srcw;
  logic [3:0]  d_cc;
  logic        d_bit_imm;
  logic [2:0]  d_bit_op;
  logic        d_conv_cdq;
  smk_e        d_sm;
  st_e         d_st;
  logic        d_str_loadsi;   // reads [ESI]
  logic        d_str_storedi;  // writes [EDI]
  logic        d_str_scandi;   // reads [EDI] for compare
  ctk_e        d_ct;
  logic [15:0] d_ret_imm;
  logic        d_cld;
  logic        d_std;
  logic        d_clc;          // CLC (F8): CF<-0
  logic        d_stc;          // STC (F9): CF<-1
  logic        d_cmc;          // CMC (F5): CF<-~CF
  logic        d_cnt16;        // 0x67 address-size: LOOP/JCXZ use CX (low 16)

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
    FX_FSQRT
  } fxop_e;

  fxop_e       d_fxop;
  logic        d_is_x87;
  logic        d_f_mem_read;     // x87 op reads a memory operand
  logic        d_f_mem_write;    // x87 op writes a memory operand
  logic [2:0]  d_f_msize;        // memory operand bytes: 2/4/8/10 (encoded as 2,4,8,10 won't fit 3b)
  logic [3:0]  d_f_mbytes;       // memory operand size in bytes (2,4,8,10)
  logic        d_f_pop;          // pop the stack after the op (1 pop)
  logic        d_f_pop2;         // pop twice (FCOMPP/FUCOMPP)
  logic [2:0]  d_f_sti;          // st(i) index operand
  logic [2:0]  d_f_aluop;        // 0=add 1=mul 4=sub 5=subr 6=div 7=divr (x87 group)
  logic [2:0]  d_f_const;        // ROM-constant selector for FLDCONST

  // ===========================================================================
  // ModR/M + SIB helpers
  // ===========================================================================
  logic [3:0]  m_idx;
  logic [1:0]  modrm_mod;
  logic [2:0]  modrm_reg;
  logic [2:0]  modrm_rm;
  logic        has_sib;
  logic [1:0]  sib_scale;
  logic [2:0]  sib_index;
  logic [2:0]  sib_base;
  logic [7:0]  mrm, sibb;

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
  // Prefix machine
  // ===========================================================================
  logic [3:0] pfx_len;
  logic       pfx_opsize, pfx_addr, pfx_seg, pfx_lock;
  logic [1:0] pfx_rep;          // 0 none, 2 F2, 3 F3
  logic [7:0] op0, op1;
  logic       two_byte;

  function automatic logic is_prefix(input logic [7:0] b);
    is_prefix = (b==8'h66)||(b==8'h67)||(b==8'h2E)||(b==8'h36)||(b==8'h3E)||
                (b==8'h26)||(b==8'h64)||(b==8'h65)||(b==8'hF0)||(b==8'hF2)||(b==8'hF3);
  endfunction

  always_comb begin
    pfx_len=4'd0; pfx_opsize=1'b0; pfx_addr=1'b0; pfx_seg=1'b0; pfx_lock=1'b0; pfx_rep=2'd0;
    for (int i=0;i<4;i++) begin
      if (is_prefix(ibuf[pfx_len])) begin
        unique case (ibuf[pfx_len])
          8'h66: pfx_opsize=1'b1;
          8'h67: pfx_addr=1'b1;
          8'hF3: pfx_rep=2'd3;
          8'hF2: pfx_rep=2'd2;
          8'hF0: pfx_lock=1'b1;
          default: pfx_seg=1'b1;
        endcase
        pfx_len = pfx_len + 4'd1;
      end
    end
    op0=ibuf[pfx_len];
    two_byte=(op0==8'h0F);
    op1=ibuf[pfx_len+4'd1];
  end

  // ===========================================================================
  // Condition codes
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
  // Width helpers
  // ===========================================================================
  function automatic logic [31:0] wmask(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return {24'd0, v[7:0]};
    else if (w==3'd2) return {16'd0, v[15:0]};
    else return v;
  endfunction
  function automatic logic sbit(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return v[7]; else if (w==3'd2) return v[15]; else return v[31];
  endfunction
  // second-highest bit (MSB-1) of width w
  function automatic logic sbit2(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return v[6]; else if (w==3'd2) return v[14]; else return v[30];
  endfunction
  function automatic logic parity8(input logic [7:0] v); return ~^v; endfunction

  // ===========================================================================
  // Combinational decoder
  // ===========================================================================
  always_comb begin
    d_len=4'd1; d_halt=1'b0; d_unknown=1'b0; d_is_branch=1'b0; d_branch_taken=1'b0;
    d_rel=32'd0; d_alu_op=ALU_ADD; d_writes_reg=1'b0; d_writes_flags=1'b0;
    d_mem_read=1'b0; d_mem_write=1'b0; d_mem_dst=1'b0; d_dst_reg=3'd0; d_src_reg=3'd0;
    d_imm=32'd0; d_use_imm=1'b0; d_is_push=1'b0; d_is_pop=1'b0; d_is_lea=1'b0;
    d_is_mov=1'b0; d_is_nop=1'b0; d_ea=32'd0; d_w=3'd4; d_dst_high8=1'b0; d_src_high8=1'b0;
    d_kind=K_ALU; d_shrot=3'd0; d_shift_cl=1'b0; d_shift_one=1'b0; d_shift_imm=5'd0;
    d_shrd=1'b0; d_md=3'd0; d_imul_3op=1'b0; d_imul_imm=32'd0; d_ext_signed=1'b0;
    d_ext_srcw=3'd1; d_cc=4'd0; d_bit_imm=1'b0; d_bit_op=3'd4; d_conv_cdq=1'b0;
    d_sm=SM_PUSHA; d_st=ST_MOVS; d_str_loadsi=1'b0; d_str_storedi=1'b0; d_str_scandi=1'b0;
    d_ct=CT_CALLREL; d_ret_imm=16'd0; d_cld=1'b0; d_std=1'b0;
    d_clc=1'b0; d_stc=1'b0; d_cmc=1'b0; d_cnt16=pfx_addr;
    d_fxop=FX_NONE; d_is_x87=1'b0; d_f_mem_read=1'b0; d_f_mem_write=1'b0;
    d_f_msize=3'd0; d_f_mbytes=4'd0; d_f_pop=1'b0; d_f_pop2=1'b0; d_f_sti=3'd0;
    d_f_aluop=3'd0; d_f_const=3'd0;

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
    end

    d_w = pfx_opsize ? 3'd2 : 3'd4;

    if (two_byte) begin
      unique casez (op1)
        8'b1000_????: begin // Jcc rel32
          d_len=pfx_len+4'd6; d_is_branch=1'b1; d_branch_taken=cond_true(op1[3:0],eflags);
          d_rel={ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1],ibuf[m_idx]};
        end
        8'b1001_????: begin // SETcc r/m8
          d_kind=K_SETCC; d_w=3'd1; d_cc=op1[3:0];
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'hB6,8'hB7,8'hBE,8'hBF: begin // MOVZX/MOVSX
          d_kind=K_EXT; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_ext_signed=(op1==8'hBE)||(op1==8'hBF);
          d_ext_srcw=((op1==8'hB6)||(op1==8'hBE))?3'd1:3'd2;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_src_high8=(d_ext_srcw==3'd1)&&modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'hAF: begin // IMUL r, r/m
          d_kind=K_IMUL2; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hA3,8'hAB,8'hB3,8'hBB: begin // BT/BTS/BTR/BTC reg
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          unique case (op1)
            8'hA3: d_bit_op=3'd4; 8'hAB: d_bit_op=3'd5; 8'hB3: d_bit_op=3'd6;
            default: d_bit_op=3'd7;
          endcase
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_writes_reg=(op1!=8'hA3); d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hBA: begin // BT/BTS/BTR/BTC imm
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_bit_imm=1'b1; d_bit_op=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_imm={24'd0,ibuf[m_idx+1]};
            d_writes_reg=(modrm_reg!=3'd4); d_len=pfx_len+4'd4;
          end else begin d_unknown=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hBC,8'hBD: begin // BSF/BSR
          d_kind=K_BITSCAN; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          d_shrd=(op1==8'hBD);
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
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
            d_unknown=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+(d_shift_cl?4'd0:4'd1);
          end
        end
        8'b1100_1???: begin // BSWAP r32
          d_kind=K_BSWAP; d_writes_reg=1'b1; d_dst_reg=op1[2:0]; d_len=pfx_len+4'd2;
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
          if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'b0100_0???: begin // INC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_INC; d_w=pfx_opsize?3'd2:3'd4;
        end
        8'b0100_1???: begin // DEC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_DEC; d_w=pfx_opsize?3'd2:3'd4;
        end
        8'b0101_0???: begin // PUSH r16/32
          d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1; d_src_reg=op0[2:0];
          d_w=pfx_opsize?3'd2:3'd4;
        end
        8'b0101_1???: begin // POP r16/32
          d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1; d_writes_reg=1'b1;
          d_dst_reg=op0[2:0]; d_w=pfx_opsize?3'd2:3'd4;
        end
        8'h60: begin d_kind=K_STKMISC; d_sm=SM_PUSHA; d_len=pfx_len+4'd1; d_w=pfx_opsize?3'd2:3'd4; end
        8'h61: begin d_kind=K_STKMISC; d_sm=SM_POPA;  d_len=pfx_len+4'd1; d_w=pfx_opsize?3'd2:3'd4; end
        8'h68: begin // PUSH imm
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1;
          if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'h6A: begin // PUSH imm8 (sign-ext)
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1; d_w=pfx_opsize?3'd2:3'd4;
          d_imm={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'h69: begin // IMUL r, r/m, imm32
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]};
            d_len=pfx_len+4'd6;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+3],
                        ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+2],
                        ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+1],
                        ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+0]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
          end
        end
        8'h6B: begin // IMUL r, r/m, imm8
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={{24{ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                        ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'b00??_?000: begin // ALU r/m8, r8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?001: begin // ALU r/m16/32, r16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?010: begin // ALU r8, r/m8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?011: begin // ALU r16/32, r/m16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?100: begin // ALU AL, imm8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'b00??_?101: begin // ALU eAX, imm16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX; d_use_imm=1'b1;
          if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'h80: begin // group1 r/m8, imm8
          d_w=3'd1; d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h81: begin // group1 r/m16/32, imm16/32
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            if (pfx_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'h83: begin // group1 r/m16/32, imm8 sign-ext
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1; d_w=pfx_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            d_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={{24{ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                   ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h84: begin // TEST r/m8, r8
          d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h85: begin // TEST r/m16/32, r16/32
          d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h86: begin // XCHG r/m8, r8
          d_kind=K_XCHG; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h87: begin // XCHG r/m16/32, r16/32
          d_kind=K_XCHG; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h88: begin // MOV r/m8, r8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h89: begin // MOV r/m16/32, r16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8A: begin // MOV r8, r/m8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_writes_reg=1'b1; d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8B: begin // MOV r16/32, r/m16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8D: begin // LEA
          d_is_lea=1'b1; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base);
        end
        8'h8F: begin // POP r/m
          d_is_pop=1'b1; d_mem_read=1'b1; d_w=pfx_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b1001_0???: begin // NOP / XCHG eAX,r
          if (op0==8'h90 && !pfx_opsize) begin d_is_nop=1'b1; d_len=pfx_len+4'd1; end
          else begin d_kind=K_XCHG; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_src_reg=op0[2:0]; d_len=pfx_len+4'd1; end
        end
        8'h98: begin d_kind=K_CONV; d_conv_cdq=1'b0; d_len=pfx_len+4'd1; end
        8'h99: begin d_kind=K_CONV; d_conv_cdq=1'b1; d_len=pfx_len+4'd1; end
        8'h9C: begin d_kind=K_STKMISC; d_sm=SM_PUSHF; d_mem_write=1'b1; d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9D: begin d_kind=K_STKMISC; d_sm=SM_POPF;  d_mem_read=1'b1;  d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9E: begin d_kind=K_STKMISC; d_sm=SM_SAHF; d_len=pfx_len+4'd1; end
        8'h9F: begin d_kind=K_STKMISC; d_sm=SM_LAHF; d_len=pfx_len+4'd1; end
        8'hA0: begin // MOV AL, moffs8 (8-bit load, preserve [31:8])
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=3'd1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_len=pfx_len+4'd5;
        end
        8'hA1: begin // MOV eAX, moffs
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd5;
        end
        8'hA2: begin // MOV moffs8, AL (8-bit store)
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=3'd1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_len=pfx_len+4'd5;
        end
        8'hA3: begin // MOV moffs, eAX
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd5;
        end
        8'hA8: begin d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2; end
        8'hA9: begin d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX; d_use_imm=1'b1;
          if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        // string ops
        8'hA4: begin d_kind=K_STR; d_st=ST_MOVS; d_w=3'd1; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA5: begin d_kind=K_STR; d_st=ST_MOVS; d_w=pfx_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAA: begin d_kind=K_STR; d_st=ST_STOS; d_w=3'd1; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAB: begin d_kind=K_STR; d_st=ST_STOS; d_w=pfx_opsize?3'd2:3'd4; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAC: begin d_kind=K_STR; d_st=ST_LODS; d_w=3'd1; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAD: begin d_kind=K_STR; d_st=ST_LODS; d_w=pfx_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAE: begin d_kind=K_STR; d_st=ST_SCAS; d_w=3'd1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAF: begin d_kind=K_STR; d_st=ST_SCAS; d_w=pfx_opsize?3'd2:3'd4; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA6: begin d_kind=K_STR; d_st=ST_CMPS; d_w=3'd1; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA7: begin d_kind=K_STR; d_st=ST_CMPS; d_w=pfx_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hC6: begin // MOV r/m8, imm8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1; d_w=3'd1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hC7: begin // MOV r/m16/32, imm
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm;
            if (pfx_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            if (pfx_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'hD0,8'hD1,8'hD2,8'hD3: begin // shift/rotate by 1 / CL
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hD0||op0==8'hD2)?3'd1:(pfx_opsize?3'd2:3'd4);
          d_shift_one=(op0==8'hD0||op0==8'hD1);
          d_shift_cl=(op0==8'hD2||op0==8'hD3);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hC0,8'hC1: begin // shift/rotate by imm8
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hC0)?3'd1:(pfx_opsize?3'd2:3'd4);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
            d_shift_imm=ibuf[m_idx+1][4:0]; d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_shift_imm=ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)][4:0];
            d_imm={24'd0,ibuf[m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hF6,8'hF7: begin // group3
          d_w=(op0==8'hF6)?3'd1:(pfx_opsize?3'd2:3'd4);
          unique case (modrm_reg)
            3'd0,3'd1: begin // TEST r/m, imm
              d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_use_imm=1'b1;
              if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
                if (d_w==3'd1) begin d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3; end
                else if (d_w==3'd2) begin d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
                else begin d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
              end else d_unknown=1'b1;
            end
            3'd2: begin // NOT
              d_alu_op=ALU_NOT;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd3: begin // NEG
              d_alu_op=ALU_NEG; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            default: begin // MUL/IMUL/DIV/IDIV
              d_kind=K_MULDIV; d_md=modrm_reg; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
          endcase
        end
        8'hFE: begin // INC/DEC r/m8
          d_w=3'd1; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hFF: begin
          unique case (modrm_reg)
            3'd0,3'd1: begin // INC/DEC r/m16/32
              d_w=pfx_opsize?3'd2:3'd4; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd2: begin // CALL r/m near
              d_kind=K_CTRL; d_ct=CT_CALLIND; d_mem_write=1'b1; d_w=3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd4: begin // JMP r/m near
              d_kind=K_CTRL; d_ct=CT_JMPIND;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd6: begin // PUSH r/m
              d_is_push=1'b1; d_mem_write=1'b1; d_w=pfx_opsize?3'd2:3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl(modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
          endcase
        end
        8'hEB: begin d_len=pfx_len+4'd2; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE9: begin d_len=pfx_len+4'd5; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; end
        8'b0111_????: begin d_len=pfx_len+4'd2; d_is_branch=1'b1;
          d_branch_taken=cond_true(op0[3:0],eflags); d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE8: begin d_kind=K_CTRL; d_ct=CT_CALLREL; d_mem_write=1'b1; d_w=pfx_opsize?3'd2:3'd4;
          // 0x66 near CALL: 16-bit rel (cw), push 16-bit next-IP, ESP-=2, and
          // EIP=(next_eip+rel16)&0xFFFF (operand-size-16 truncates EIP).
          if (pfx_opsize) begin d_rel={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hC3: begin d_kind=K_CTRL; d_ct=CT_RETN; d_mem_read=1'b1; d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hC2: begin d_kind=K_CTRL; d_ct=CT_RETN_IMM; d_mem_read=1'b1; d_w=pfx_opsize?3'd2:3'd4;
          d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
        8'hC9: begin d_kind=K_STKMISC; d_sm=SM_LEAVE; d_mem_read=1'b1; d_w=pfx_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hE2: begin d_kind=K_CTRL; d_ct=CT_LOOP;   d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE1: begin d_kind=K_CTRL; d_ct=CT_LOOPE;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE0: begin d_kind=K_CTRL; d_ct=CT_LOOPNE; d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE3: begin d_kind=K_CTRL; d_ct=CT_JECXZ;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hFC: begin d_cld=1'b1; d_len=pfx_len+4'd1; end
        8'hFD: begin d_std=1'b1; d_len=pfx_len+4'd1; end
        8'hF8: begin d_clc=1'b1; d_len=pfx_len+4'd1; end // CLC: CF<-0
        8'hF9: begin d_stc=1'b1; d_len=pfx_len+4'd1; end // STC: CF<-1
        8'hF5: begin d_cmc=1'b1; d_len=pfx_len+4'd1; end // CMC: CF<-~CF
        8'hCD: begin d_len=pfx_len+4'd2; d_halt=(ibuf[pfx_len+1]==8'h80); end

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
          else                  d_len = m_idx + mfl(modrm_mod,modrm_rm,has_sib,sib_base);
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
                  3'd5: begin d_fxop=FX_FLDCW;    d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd7: begin d_fxop=FX_FNSTCW;   d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;   // /4 FLDENV /6 FNSTENV deferred
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
                  3'd7: begin d_fxop=FX_FNSTSW_M; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;   // FRSTOR/FSAVE deferred
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
                  3'd5: begin d_fxop=FX_FILD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd7: begin d_fxop=FX_FIST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;   // FBLD/FBSTP deferred
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
  end

  // ===========================================================================
  // Latched decoded fields
  // ===========================================================================
  logic [3:0]  q_len;
  logic        q_is_branch, q_branch_taken;
  logic [31:0] q_rel;
  logic [4:0]  q_alu_op;
  logic        q_writes_reg, q_writes_flags, q_mem_read, q_mem_write, q_mem_dst;
  logic [2:0]  q_dst_reg, q_src_reg;
  logic [31:0] q_imm;
  logic        q_use_imm, q_is_push, q_is_pop, q_is_lea, q_is_mov;
  logic [31:0] q_ea, q_pc;
  logic [2:0]  q_w;
  logic        q_dst_high8, q_src_high8;
  kind_e       q_kind;
  logic [2:0]  q_shrot;
  logic        q_shift_cl, q_shift_one;
  logic [4:0]  q_shift_imm;
  logic        q_shrd;
  logic [2:0]  q_md;
  logic        q_imul_3op;
  logic [31:0] q_imul_imm;
  logic        q_ext_signed;
  logic [2:0]  q_ext_srcw;
  logic [3:0]  q_cc;
  logic        q_bit_imm;
  logic [2:0]  q_bit_op;
  logic        q_conv_cdq;
  smk_e        q_sm;
  st_e         q_st;
  logic        q_rep, q_repne, q_str_loadsi, q_str_storedi, q_str_scandi;
  ctk_e        q_ct;
  logic [15:0] q_ret_imm;
  logic        q_cld, q_std;
  logic        q_clc, q_stc, q_cmc;
  logic        q_cnt16;

  // latched x87 decode
  fxop_e       q_fxop;
  logic        q_is_x87;
  logic        q_f_mem_read, q_f_mem_write;
  logic [3:0]  q_f_mbytes;
  logic        q_f_pop, q_f_pop2;
  logic [2:0]  q_f_sti, q_f_aluop, q_f_const;
  logic [3:0]  f_step;             // x87 memory beat counter
  logic [79:0] f_mem80;            // assembled memory operand (m16/32/64/80)

  logic [31:0] mem_load_data, mem_load_data2;
  logic [3:0]  step;            // micro-sequence step counter
  logic [31:0] str_next_eip;    // EIP target after a string element commit
  logic [31:0] str_store_addr;  // [EDI] (pre-increment) for a MOVS/STOS store
  logic [31:0] str_store_data;  // value to store this string element
  logic [31:0] pusha_esp;       // original ESP latched for PUSHA

  // ===========================================================================
  // Register read/merge with partial semantics
  // ===========================================================================
  // r is the PHYSICAL gpr index (decode already maps AH..BH -> EAX..EBX);
  // high8 selects bits [15:8] for 8-bit ops.
  function automatic logic [31:0] reg_read(input logic [2:0] r, input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_read = {24'd0, gpr[r][15:8]};
        else       reg_read = {24'd0, gpr[r][7:0]};
      end else if (w==3'd2) reg_read = {16'd0, gpr[r][15:0]};
      else reg_read = gpr[r];
    end
  endfunction

  function automatic logic [31:0] reg_merge(input logic [31:0] cur, input logic [31:0] res,
                                            input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_merge = {cur[31:16], res[7:0], cur[7:0]};
        else       reg_merge = {cur[31:8], res[7:0]};
      end else if (w==3'd2) reg_merge = {cur[31:16], res[15:0]};
      else reg_merge = res;
    end
  endfunction

  // ===========================================================================
  // ALU result + EFLAGS at width w
  // ===========================================================================
  function automatic logic [31:0] alu_result(input logic [4:0] op, input logic [31:0] a,
                                             input logic [31:0] b, input logic cfin);
    unique case (op)
      ALU_ADD, ALU_INC: alu_result=a+b;
      ALU_SUB, ALU_CMP, ALU_DEC: alu_result=a-b;
      ALU_AND, ALU_TEST: alu_result=a&b;
      ALU_OR:  alu_result=a|b;
      ALU_XOR: alu_result=a^b;
      ALU_MOV: alu_result=b;
      ALU_ADC: alu_result=a+b+{31'd0,cfin};
      ALU_SBB: alu_result=a-b-{31'd0,cfin};
      ALU_NEG: alu_result=32'd0-a;
      ALU_NOT: alu_result=~a;
      default: alu_result=a;
    endcase
  endfunction

  function automatic logic [31:0] flags_next(input logic [4:0] op, input logic [31:0] a,
                                             input logic [31:0] b, input logic [31:0] res_full,
                                             input logic [31:0] cur, input logic [2:0] w);
    logic cf,pf,af,zf,sf,of;
    logic [31:0] fl,res,am,bm;
    logic [32:0] uadd,usub,uadc,usbb;
    int msb, cpos;
    begin
      res=wmask(res_full,w); am=wmask(a,w); bm=wmask(b,w);
      msb=(w==3'd1)?7:((w==3'd2)?15:31);
      cpos=(w==3'd1)?8:((w==3'd2)?16:32);
      zf=(res==32'd0); sf=sbit(res,w); pf=parity8(res[7:0]);
      uadd={1'b0,am}+{1'b0,bm};
      usub={1'b0,am}-{1'b0,bm};
      uadc={1'b0,am}+{1'b0,bm}+{32'd0,cur[0]};
      usbb={1'b0,am}-{1'b0,bm}-{32'd0,cur[0]};
      cf=cur[0]; af=cur[4]; of=cur[11];
      unique case (op)
        ALU_ADD: begin cf=uadd[cpos]; af=(am[4]^bm[4]^res[4]); of=(~(am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_ADC: begin cf=uadc[cpos]; af=(am[4]^bm[4]^res[4]); of=(~(am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_SUB, ALU_CMP: begin cf=usub[cpos]; af=(am[4]^bm[4]^res[4]); of=((am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_SBB: begin cf=usbb[cpos]; af=(am[4]^bm[4]^res[4]); of=((am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_INC: begin cf=cur[0]; af=(am[4]^bm[4]^res[4]); of=(res[msb] && !am[msb]); end
        ALU_DEC: begin cf=cur[0]; af=(am[4]^bm[4]^res[4]); of=(!res[msb] && am[msb]); end
        ALU_NEG: begin cf=(am!=32'd0); af=(am[4]^res[4]); of=(am[msb] & res[msb]); end
        ALU_AND, ALU_OR, ALU_XOR, ALU_TEST: begin cf=1'b0; af=1'b0; of=1'b0; end
        default: begin cf=cur[0]; af=cur[4]; of=cur[11]; end
      endcase
      fl=cur & 32'hFFFF_F72A;
      fl[0]=cf; fl[2]=pf; fl[4]=af; fl[6]=zf; fl[7]=sf; fl[11]=of; fl[1]=1'b1;
      return fl;
    end
  endfunction

  // ===========================================================================
  // Shift/rotate result + CF
  // ===========================================================================
  function automatic logic [31:0] shrot_result(input logic [2:0] subop, input logic [31:0] v,
                                               input logic [5:0] cnt, input logic cfin, input logic [2:0] w);
    logic [31:0] x; logic [5:0] bits; logic carry, nc; int i; logic [4:0] ihi;
    begin
      x=wmask(v,w); bits=(w==3'd1)?6'd8:((w==3'd2)?6'd16:6'd32);
      ihi=5'(bits-6'd1);
      unique case (subop)
        3'd4,3'd6: x = wmask(x << cnt, w);
        3'd5:      x = x >> cnt;
        3'd7: begin
          if (w==3'd1)      x=$unsigned($signed({{24{v[7]}},v[7:0]})>>>cnt);
          else if (w==3'd2) x=$unsigned($signed({{16{v[15]}},v[15:0]})>>>cnt);
          else              x=$unsigned($signed(v)>>>cnt);
          x=wmask(x,w);
        end
        3'd0: for (i=0;i<32;i++) if (i<cnt) x=wmask((x<<1)|{31'd0,x[ihi]},w);
        3'd1: for (i=0;i<32;i++) if (i<cnt) x=wmask((x>>1)|({31'd0,x[0]}<<(bits-6'd1)),w);
        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end end
        default: ;
      endcase
      return wmask(x,w);
    end
  endfunction

  function automatic logic shrot_cf(input logic [2:0] subop, input logic [31:0] v,
                                    input logic [5:0] cnt, input logic cfin, input logic [2:0] w);
    logic [31:0] x,res; logic [5:0] bits; logic carry,nc; int i;
    logic [4:0] ihi, ilo, ic;
    begin
      x=wmask(v,w); bits=(w==3'd1)?6'd8:((w==3'd2)?6'd16:6'd32);
      ihi=5'(bits-6'd1);        // top bit index of the width
      ilo=5'(bits-cnt);         // SHL CF source bit
      ic =5'(cnt-6'd1);         // SHR/SAR CF source bit
      unique case (subop)
        3'd4,3'd6: shrot_cf=(cnt==0)?cfin:x[ilo];
        3'd5,3'd7: shrot_cf=(cnt==0)?cfin:x[ic];
        3'd0: begin res=shrot_result(3'd0,v,cnt,cfin,w); shrot_cf=(cnt==0)?cfin:res[0]; end
        3'd1: begin res=shrot_result(3'd1,v,cnt,cfin,w); shrot_cf=(cnt==0)?cfin:res[ihi]; end
        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end shrot_cf=carry; end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end shrot_cf=carry; end
        default: shrot_cf=cfin;
      endcase
    end
  endfunction

  // SHLD/SHRD (16/32-bit only)
  function automatic logic [31:0] shld_result(input logic is_shrd, input logic [31:0] dst,
                                              input logic [31:0] src, input logic [5:0] cnt, input logic [2:0] w);
    logic [31:0] r; logic [5:0] bits;
    begin
      bits=(w==3'd2)?6'd16:6'd32;
      if (cnt==0) r=dst;
      else if (is_shrd) r=(dst>>cnt)|(src<<(bits-cnt));
      else              r=(dst<<cnt)|(src>>(bits-cnt));
      return wmask(r,w);
    end
  endfunction
  function automatic logic shld_cf(input logic is_shrd, input logic [31:0] dst,
                                   input logic [5:0] cnt, input logic [2:0] w);
    logic [5:0] bits; logic [4:0] ilo, ic;
    begin
      bits=(w==3'd2)?6'd16:6'd32;
      ilo=5'(bits-cnt); ic=5'(cnt-6'd1);
      if (cnt==0) shld_cf=1'b0;
      else if (is_shrd) shld_cf=dst[ic];
      else shld_cf=dst[ilo];
    end
  endfunction

  // ===========================================================================
  // EXEC combinational operands
  // ===========================================================================
  logic [31:0] dst_cur, a_op, b_op, alu_out, flags_out;
  logic [5:0]  sh_cnt;
  logic [31:0] sh_val, sh_out, sh_shm1;
  logic        sh_cfout;

  always_comb begin
    dst_cur = gpr[q_dst_reg];
    a_op = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_use_imm) b_op = wmask(q_imm,q_w);
    else if (q_mem_read && !q_mem_dst) b_op = wmask(mem_load_data,q_w);
    else if (q_alu_op==ALU_INC || q_alu_op==ALU_DEC) b_op = 32'd1;
    else b_op = reg_read(q_src_reg,q_w,q_src_high8);
    alu_out   = alu_result(q_alu_op, a_op, b_op, eflags[0]);
    flags_out = flags_next(q_alu_op, a_op, b_op, alu_out, eflags, q_w);

    sh_val = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_shift_one) sh_cnt = 6'd1;
    else if (q_shift_cl) sh_cnt = {1'b0, gpr[R_ECX][4:0]};
    else sh_cnt = {1'b0, q_shift_imm};
    sh_out   = shrot_result(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    sh_cfout = shrot_cf(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    // shm1 = the operand shifted by (count-1), per QEMU CC_SRC for SHL/SHR/SAR.
    sh_shm1  = (sh_cnt==6'd0) ? sh_val : shrot_result(q_shrot, sh_val, sh_cnt-6'd1, eflags[0], q_w);
  end

  // ===========================================================================
  // Retire snapshot
  // ===========================================================================
  logic [31:0] next_eip;
  assign next_eip = q_pc + {28'd0, q_len};

  arch_state_t snap;
  always_comb begin
    snap.eflags=eflags;
    snap.eax=gpr[0]; snap.ecx=gpr[1]; snap.edx=gpr[2]; snap.ebx=gpr[3];
    snap.esp=gpr[4]; snap.ebp=gpr[5]; snap.esi=gpr[6]; snap.edi=gpr[7];
    snap.cs=SEG_CS; snap.ss=SEG_SS; snap.ds=SEG_DS; snap.es=SEG_ES; snap.fs=SEG_FS; snap.gs=SEG_GS;
  end
  assign retire_state=snap;
  assign retire_pc=q_pc;

  // ===========================================================================
  // String addressing + direction
  // ===========================================================================
  logic        df;
  assign df = eflags[10];
  logic [31:0] str_step;        // +/- width
  assign str_step = df ? (32'd0 - {29'd0,q_w}) : {29'd0,q_w};

  // ===========================================================================
  // Store-operand resolution (combinational) used in S_STORE.
  // The per-op store address/data/strobe are computed from latched fields.
  // ===========================================================================
  function automatic logic [3:0] strb_of(input logic [2:0] w);
    if (w==3'd1) return 4'b0001; else if (w==3'd2) return 4'b0011; else return 4'b1111;
  endfunction

  logic [31:0] st_addr, st_data;
  logic [3:0]  st_strb;
  logic [31:0] call_target;

  logic [31:0] call_t16;  // 0x66 near-CALL truncated target (declared at top to
                          // avoid an inferred latch on a branch-local var)
  always_comb begin
    // default store: a memory destination (RMW / mov [m],r / setcc [m])
    st_strb = strb_of(q_w);
    st_addr = q_ea;
    st_data = 32'd0;
    call_t16 = next_eip + q_rel;

    // resolve store data by op kind
    if (q_is_push) begin
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      st_data = q_use_imm ? q_imm
              : (q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0));
    end else if (q_kind==K_CTRL && (q_ct==CT_CALLREL || q_ct==CT_CALLIND)) begin
      // Near CALL pushes the next-IP at the operand width: 4 bytes (32-bit) or
      // 2 bytes for a 0x66-prefixed 16-bit near CALL.
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      st_data = next_eip;
      st_strb = strb_of(q_w);
    end else if (q_kind==K_STKMISC && q_sm==SM_PUSHF) begin
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      st_data = eflags;
    end else if (q_kind==K_SETCC) begin
      st_data = {31'd0, cond_true(q_cc, eflags)};
      st_strb = 4'b0001;
    end else if (q_kind==K_SHIFT) begin
      st_data = sh_out;
    end else if (q_kind==K_XCHG) begin
      st_data = reg_read(q_src_reg,q_w,q_src_high8);
    end else if (q_is_pop) begin
      // POP m: write the popped stack word to the memory destination.
      st_data = mem_load_data;
    end else if (q_is_mov) begin
      st_data = q_use_imm ? q_imm : reg_read(q_src_reg,q_w,q_src_high8);
    end else begin
      // ALU RMW / NEG / NOT / INC / DEC to memory
      st_data = alu_out;
    end

    // CALL/JMP indirect target
    if (q_ct==CT_CALLIND || q_ct==CT_JMPIND)
      call_target = q_mem_read ? mem_load_data : gpr[q_src_reg];
    else if (q_kind==K_CTRL && q_ct==CT_CALLREL && q_w==3'd2)
      // 0x66 near CALL: operand-size-16 truncates the target EIP to 16 bits.
      call_target = {16'd0, call_t16[15:0]};
    else
      call_target = next_eip + q_rel;
  end

  // ===========================================================================
  // String element operand (combinational): value to write/compare this iter.
  // ===========================================================================
  logic [31:0] str_wdata;    // value to store at [EDI]
  logic [31:0] str_a, str_b; // SCAS/CMPS compare operands
  logic [31:0] str_flags;
  always_comb begin
    // value to store:
    //  MOVS -> [ESI] (mem_load_data)
    //  STOS -> AL/AX/EAX
    unique case (q_st)
      ST_MOVS: str_wdata = mem_load_data;
      ST_STOS: str_wdata = reg_read(R_EAX,q_w,1'b0);
      default: str_wdata = mem_load_data;
    endcase
    // SCAS: compare EAX(width) - [EDI];  CMPS: [ESI] - [EDI]
    if (q_st==ST_SCAS) begin str_a = reg_read(R_EAX,q_w,1'b0); str_b = wmask(mem_load_data,q_w); end
    else /*CMPS*/        begin str_a = wmask(mem_load_data,q_w); str_b = wmask(mem_load_data2,q_w); end
    str_flags = flags_next(ALU_CMP, str_a, str_b, str_a - str_b, eflags, q_w);
  end

  // ===========================================================================
  // x87 combinational execution (M3)
  // ===========================================================================
  // st(i) read helper on the physical regfile (st0 = fpr[ftop]).
  function automatic logic [2:0] fri(input logic [2:0] i); return ftop + i; endfunction
  function automatic logic [79:0] fst(input logic [2:0] i); return fpr[ftop + i]; endfunction

  // Compare two floatx80, return {C3,C2,C0} per QEMU fcom_ccval. The C1 bit is
  // left to the caller (compares clear only C3/C2/C0). less->001, equal->100,
  // greater->000, unordered->111 (unordered also when either is NaN).
  function automatic logic [2:0] fcom_codes(input logic [79:0] a, input logic [79:0] b);
    logic an, bn;   // NaN? (exp all-ones, mantissa != the pure-infinity pattern)
    begin
      an = (fx_exp(a)==15'h7fff) && (fx_man(a)!=64'h8000000000000000);
      bn = (fx_exp(b)==15'h7fff) && (fx_man(b)!=64'h8000000000000000);
      if (an || bn) fcom_codes = 3'b111;           // unordered: C3=1,C2=1,C0=1
      else if (fx_is_zero(a) && fx_is_zero(b)) fcom_codes = 3'b100;  // +0==-0 equal
      else if (fst_lt(a,b)) fcom_codes = 3'b001;   // less:  C0=1
      else if (fst_eq(a,b)) fcom_codes = 3'b100;   // equal: C3=1
      else                  fcom_codes = 3'b000;   // greater
    end
  endfunction
  // Ordered numeric < and == on normal/zero floatx80 (no NaN here).
  function automatic logic fst_eq(input logic [79:0] a, input logic [79:0] b);
    if (fx_is_zero(a) && fx_is_zero(b)) return 1'b1;
    return (a==b);
  endfunction
  function automatic logic fst_lt(input logic [79:0] a, input logic [79:0] b);
    logic sa, sb;
    logic [78:0] mag_a, mag_b;
    begin
      if (fx_is_zero(a) && fx_is_zero(b)) return 1'b0;
      sa=fx_sign(a); sb=fx_sign(b);
      mag_a = a[78:0]; mag_b = b[78:0];   // exp:mant magnitude
      if (fx_is_zero(a)) sa = sb ? 1'b0 : 1'b0;  // 0 vs nonzero handled by mag below
      if (sa != sb) return sa & ~(fx_is_zero(a)&&fx_is_zero(b));  // a<b if a negative
      // same sign: compare magnitudes
      if (!sa) return (mag_a < mag_b);   // both positive
      else     return (mag_a > mag_b);   // both negative: larger magnitude is smaller
    end
  endfunction

  // NaN classifiers on floatx80 (x86 convention, snan_bit_is_one=false). A NaN
  // has exp==0x7fff and is not the pure-infinity pattern (mantissa 0x8000..).
  // QNaN = the quiet bit (mantissa bit 62) is set; SNaN = quiet bit clear with
  // some other mantissa bit set. Mirrors softfloat floatx80_is_{quiet,signaling}.
  function automatic logic fx_is_nan(input logic [79:0] v);
    return (fx_exp(v)==15'h7fff) && (fx_man(v)!=64'h8000000000000000);
  endfunction
  function automatic logic fx_is_snan(input logic [79:0] v);
    // exp all-ones, quiet bit (62) clear, and (low<<1) with bit62 masked != 0.
    return (fx_exp(v)==15'h7fff) && !fx_man(v)[62] &&
           (({fx_man(v)[63], 1'b0, fx_man(v)[61:0]} << 1) != 64'd0);
  endfunction

  // Compare-time invalid (#IA) per QEMU: FCOM/FTST/FICOM use floatx80_compare
  // (SIGNALING) -> IE on ANY NaN operand; FUCOM uses floatx80_compare_quiet ->
  // IE only on a SIGNALING NaN. `signaling` selects which rule applies.
  function automatic logic fcom_ie(input logic [79:0] a, input logic [79:0] b,
                                    input logic signaling);
    if (signaling) return fx_is_nan(a) || fx_is_nan(b);
    else           return fx_is_snan(a) || fx_is_snan(b);
  endfunction

  // Apply compare condition codes to fstat: clear C3/C2/C0 (mask 0x4500, NOT C1)
  // and set per {C3,C2,C0} (QEMU helper_fcom: fpus = (fpus & ~0x4500) | ccval).
  // `ie` latches the invalid-operation flag (fstat bit0), sticky, when the
  // compare is unordered against a NaN that the op signals on.
  function automatic logic [15:0] apply_cmp(input logic [15:0] cur,
                                            input logic [2:0] codes, input logic ie);
    logic [15:0] r;
    begin
      r = cur & ~16'h4500;
      if (codes[2]) r[14] = 1'b1;   // C3
      if (codes[1]) r[10] = 1'b1;   // C2
      if (codes[0]) r[8]  = 1'b1;   // C0
      if (ie)       r[0]  = 1'b1;   // IE (sticky)
      return r;
    end
  endfunction

  // The ROM constants QEMU emits (default rounding). 80-bit canonical.
  function automatic logic [79:0] fconst(input logic [2:0] sel);
    unique case (sel)
      3'd0: fconst = 80'h3fff8000000000000000;          // 1.0
      3'd1: fconst = 80'h4000d49a784bcd1b8afe;          // log2(10)
      3'd2: fconst = 80'h3fffb8aa3b295c17f0bc;          // log2(e)
      3'd3: fconst = 80'h4000c90fdaa22168c235;          // pi
      3'd4: fconst = 80'h3ffd9a209a84fbcff799;          // log10(2)
      3'd5: fconst = 80'h3ffeb17217f7d1cf79ac;          // ln(2)
      default: fconst = 80'h00000000000000000000;       // 0.0
    endcase
  endfunction

  // FXAM condition codes {C3,C2,C1,C0} per QEMU helper_fxam_ST0 (C1=sign always).
  function automatic logic [3:0] fxam_codes(input logic [79:0] v, input logic empty);
    logic c1;
    logic [14:0] e;
    logic [63:0] m;
    begin
      c1 = v[79];                    // C1 = sign bit (set even when empty)
      if (empty) return {1'b1, 1'b0, c1, 1'b1};   // Empty: C3=1,C2=0,C0=1
      e = fx_exp(v); m = fx_man(v);
      if (e==15'h7fff) begin
        // QEMU helper_fxam_ST0: Inf -> 0x500 (C2+C0), NaN -> 0x100 (C0). The C1
        // sign bit (0x200) is overlaid by the caller for both.
        if (m==64'h8000000000000000) return {1'b0,1'b1,c1,1'b1};  // Inf: C2=1,C0=1 (0x500)
        else                          return {1'b0,1'b0,c1,1'b1};  // NaN: C0=1   (0x100)
      end else if (e==15'd0) begin
        if (m==64'd0) return {1'b1,1'b0,c1,1'b0};   // Zero: C3=1
        else          return {1'b1,1'b1,c1,1'b0};   // Denormal: C3=1,C2=1
      end else begin
        return {1'b0,1'b1,c1,1'b0};                 // Normal: C2=1
      end
    end
  endfunction

  // The assembled memory operand value -> floatx80, by size/kind.
  function automatic logic [79:0] f_mem_as_float(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd4:  f_mem_as_float = fx_from_f32(m80[31:0]);
      4'd8:  f_mem_as_float = fx_from_f64(m80[63:0]);
      default: f_mem_as_float = m80;     // m80 already floatx80
    endcase
  endfunction
  function automatic logic [79:0] f_mem_as_int(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd2:  f_mem_as_int = fx_from_int({{48{m80[15]}}, m80[15:0]});
      4'd4:  f_mem_as_int = fx_from_int({{32{m80[31]}}, m80[31:0]});
      default: f_mem_as_int = fx_from_int($signed(m80[63:0]));
    endcase
  endfunction

  // ARITHMETIC: compute {inexact, result} for ST(dst) given two floatx80 ops and
  // the x87 group sub-op (0 add,1 mul,4 sub,5 subr,6 div,7 divr). For the memory/
  // ST0-dest forms, a=ST0, b=mem/ST(i). For STI-dest forms, a=ST(i), b=ST0.
  function automatic logic [80:0] f_arith(input logic [2:0] sub,
                                          input logic [79:0] a, input logic [79:0] b,
                                          input logic [1:0] rc);
    unique case (sub)
      3'd0: f_arith = fx_add(a, b, rc);                       // add
      3'd1: f_arith = fx_mul(a, b, rc);                       // mul
      3'd4: f_arith = fx_add(a, {~b[79], b[78:0]}, rc);       // sub: a - b
      3'd5: f_arith = fx_add(b, {~a[79], a[78:0]}, rc);       // subr: b - a
      3'd6: f_arith = fx_div(a, b, rc);                       // div: a / b
      default: f_arith = fx_div(b, a, rc);                    // divr: b / a
    endcase
  endfunction

  // The two arithmetic operands for the current x87 op, in the canonical
  // (dividend/divisor, minuend/subtrahend) order f_arith expects, so the
  // execute stage can pre-test them for the special cases QEMU handles
  // explicitly (0/0 -> QNaN+IE, x/0 -> Inf+ZE, sqrt(neg) -> QNaN+IE) WITHOUT
  // duplicating the per-form operand selection. `fa` is the left operand,
  // `fb` the right, matching f_arith(sub, fa, fb).
  function automatic logic f_div_by_zero(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b);
    // x/0 with x finite-nonzero. Only the div/divr group can zero-divide.
    unique case (sub)
      3'd6:    return fx_is_zero(b) && !fx_is_zero(a) && !fx_is_nan(a);  // a/b
      3'd7:    return fx_is_zero(a) && !fx_is_zero(b) && !fx_is_nan(b);  // b/a
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic f_zero_over_zero(input logic [2:0] sub,
                                            input logic [79:0] a, input logic [79:0] b);
    unique case (sub)
      3'd6:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      3'd7:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      default: return 1'b0;
    endcase
  endfunction

  // Full arithmetic evaluation with the exception cases QEMU handles explicitly
  // for masked, default-control operands. Returns {ie, ze, inexact, result}:
  //   0/0          -> real-indefinite QNaN, IE                 (helper_fdiv)
  //   x/0 (x!=0)   -> signed Inf, ZE                           (helper_fdiv)
  //   otherwise    -> normal-operand datapath via f_arith, PE = inexact.
  // (a,b) are in f_arith canonical order: div = a/b, divr = b/a, etc.
  function automatic logic [82:0] f_eval(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc);
    logic [80:0] r;
    begin
      if (f_zero_over_zero(sub, a, b))
        f_eval = {1'b1, 1'b0, 1'b0, 80'hFFFFC000000000000000};   // IE, indefinite
      else if (f_div_by_zero(sub, a, b)) begin
        r = f_arith(sub, a, b, rc);                              // fx_div -> signed Inf
        f_eval = {1'b0, 1'b1, 1'b0, r[79:0]};                   // ZE
      end else begin
        r = f_arith(sub, a, b, rc);
        f_eval = {1'b0, 1'b0, r[80], r[79:0]};                  // PE = inexact
      end
    end
  endfunction

  // Latch arithmetic status flags (sticky) into fstat from f_eval's flag bits.
  function automatic logic [15:0] f_arith_fstat(input logic [15:0] cur,
                                                input logic [82:0] arf);
    logic [15:0] r;
    begin
      r = cur;
      if (arf[82]) r[0] = 1'b1;   // IE
      if (arf[81]) r[2] = 1'b1;   // ZE
      if (arf[80]) r[5] = 1'b1;   // PE
      return r;
    end
  endfunction

  // ===========================================================================
  // x87 retire snapshot (TOP-relative st0..st7, fstat with TOP overlaid)
  // ===========================================================================
  assign retire_x87_touched = x87_touched_r;
  assign retire_fctrl = fctrl;
  assign retire_fstat = (fstat & ~16'h3800) | ({13'd0, ftop} << 11);
  assign retire_ftag  = 16'h0000;       // QEMU gdbstub abridges ftag to 0
  assign retire_st0 = fpr[ftop + 3'd0];
  assign retire_st1 = fpr[ftop + 3'd1];
  assign retire_st2 = fpr[ftop + 3'd2];
  assign retire_st3 = fpr[ftop + 3'd3];
  assign retire_st4 = fpr[ftop + 3'd4];
  assign retire_st5 = fpr[ftop + 3'd5];
  assign retire_st6 = fpr[ftop + 3'd6];
  assign retire_st7 = fpr[ftop + 3'd7];

  // ===========================================================================
  // Main sequential FSM
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state<=S_RESET; eip<=init_eip; eflags<=EFLAGS_RESET;
      gpr[0]<=32'd0; gpr[1]<=32'd0; gpr[2]<=32'd0; gpr[3]<=32'd0;
      gpr[4]<=init_esp; gpr[5]<=32'd0; gpr[6]<=32'd0; gpr[7]<=32'd0;
      fetch_word<=3'd0; retire_valid<=1'b0; step<=4'd0;
      // x87 reset = FNINIT state (control 0x037f, status 0, TOP 0, all empty).
      ftop<=3'd0; fctrl<=16'h037f; fstat<=16'h0000; fptag<=8'hFF;
      x87_touched_r<=1'b0; f_step<=4'd0;
      for (int fi=0; fi<8; fi++) fpr[fi]<=80'd0;
    end else begin
      retire_valid <= 1'b0;
      // x87-touched defaults low each cycle; only the x87 retire paths
      // (S_FEXEC / S_FSTORE) raise it, so the DPI x87 hook fires only for FPU
      // instructions. (ventium_top gates vtm_retire_x87 on this.)
      x87_touched_r <= 1'b0;

      unique case (state)
        S_RESET: begin fetch_word<=3'd0; state<=S_FETCH; end

        S_FETCH: begin
          if (mem_ack) begin
            ibuf[{fetch_word,2'b00}+0]<=mem_rdata[7:0];
            ibuf[{fetch_word,2'b00}+1]<=mem_rdata[15:8];
            ibuf[{fetch_word,2'b00}+2]<=mem_rdata[23:16];
            ibuf[{fetch_word,2'b00}+3]<=mem_rdata[31:24];
            if (fetch_word==3'(IWORDS-1)) begin fetch_word<=3'd0; state<=S_DECODE; end
            else fetch_word<=fetch_word+3'd1;
          end
        end

        S_DECODE: begin
          q_len<=d_len; q_is_branch<=d_is_branch; q_branch_taken<=d_branch_taken;
          q_rel<=d_rel; q_alu_op<=d_alu_op; q_writes_reg<=d_writes_reg;
          q_writes_flags<=d_writes_flags; q_mem_read<=d_mem_read; q_mem_write<=d_mem_write;
          q_mem_dst<=d_mem_dst; q_dst_reg<=d_dst_reg; q_src_reg<=d_src_reg; q_imm<=d_imm;
          q_use_imm<=d_use_imm; q_is_push<=d_is_push; q_is_pop<=d_is_pop; q_is_lea<=d_is_lea;
          q_is_mov<=d_is_mov; q_ea<=d_ea; q_pc<=eip; q_w<=d_w; q_dst_high8<=d_dst_high8;
          q_src_high8<=d_src_high8; q_kind<=d_kind; q_shrot<=d_shrot; q_shift_cl<=d_shift_cl;
          q_shift_one<=d_shift_one; q_shift_imm<=d_shift_imm; q_shrd<=d_shrd; q_md<=d_md;
          q_imul_3op<=d_imul_3op; q_imul_imm<=d_imul_imm; q_ext_signed<=d_ext_signed;
          q_ext_srcw<=d_ext_srcw; q_cc<=d_cc; q_bit_imm<=d_bit_imm; q_bit_op<=d_bit_op;
          q_conv_cdq<=d_conv_cdq; q_sm<=d_sm; q_st<=d_st; q_rep<=(pfx_rep==2'd3);
          q_repne<=(pfx_rep==2'd2); q_str_loadsi<=d_str_loadsi; q_str_storedi<=d_str_storedi;
          q_str_scandi<=d_str_scandi; q_ct<=d_ct; q_ret_imm<=d_ret_imm;
          q_cld<=d_cld; q_std<=d_std; step<=4'd0;
          q_clc<=d_clc; q_stc<=d_stc; q_cmc<=d_cmc; q_cnt16<=d_cnt16;
          // latch x87 decode
          q_fxop<=d_fxop; q_is_x87<=d_is_x87; q_f_mem_read<=d_f_mem_read;
          q_f_mem_write<=d_f_mem_write; q_f_mbytes<=d_f_mbytes; q_f_pop<=d_f_pop;
          q_f_pop2<=d_f_pop2; q_f_sti<=d_f_sti; q_f_aluop<=d_f_aluop; q_f_const<=d_f_const;
          f_step<=4'd0;

          if (d_halt || d_unknown) state<=S_HALT;
          else if (d_is_x87) begin
            if (d_f_mem_read) state<=S_FLOAD;       // read mem operand first
            else state<=S_FEXEC;                    // reg/const/control op
          end
          else if (d_kind==K_STR) begin
            // REP with ECX==0: degenerate single no-op record (advance EIP).
            if ((pfx_rep!=2'd0) && (gpr[R_ECX]==32'd0)) state<=S_EXEC; // handled as no-op
            else if (d_mem_read) state<=S_LOAD;   // movs/lods/scas/cmps load first
            else state<=S_EXEC;                    // stos stores directly
          end
          else if (d_mem_read || d_is_pop ||
                   (d_kind==K_STKMISC && (d_sm==SM_LEAVE || d_sm==SM_POPF)))
            state<=S_LOAD;
          else state<=S_EXEC;
        end

        S_LOAD: begin
          if (mem_ack) begin
            mem_load_data<=mem_rdata;
            if (q_kind==K_STR && q_st==ST_CMPS) state<=S_LOAD2;
            else state<=S_EXEC;
          end
        end
        S_LOAD2: begin
          if (mem_ack) begin mem_load_data2<=mem_rdata; state<=S_EXEC; end
        end

        // -------------------------------------------------------------------
        // S_FLOAD: read the x87 memory operand (m16/m32 = 1 word, m64 = 2,
        // m80 = 3) into f_mem80, LSB-first. Bus addresses q_ea + 4*f_step.
        // -------------------------------------------------------------------
        S_FLOAD: begin
          if (mem_ack) begin
            unique case (f_step)
              4'd0: f_mem80[31:0]  <= mem_rdata;
              4'd1: f_mem80[63:32] <= mem_rdata;
              default: f_mem80[79:64] <= mem_rdata[15:0];
            endcase
            // total words needed: m16/m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              f_step<=4'd0; state<=S_FEXEC;
            end else f_step<=f_step+4'd1;
          end
        end

        // -------------------------------------------------------------------
        S_EXEC: begin
          logic do_store, do_retire;
          logic [31:0] new_eip;
          logic flags_we;
          logic [31:0] flags_val;
          do_store=1'b0; do_retire=1'b1; new_eip=next_eip; flags_we=q_writes_flags; flags_val=flags_out;

          if (q_cld) begin eflags<=eflags & ~32'h0000_0400; flags_we=1'b0; end
          else if (q_std) begin eflags<=eflags | 32'h0000_0400; flags_we=1'b0; end
          else if (q_clc) begin eflags<=eflags & ~32'h0000_0001; flags_we=1'b0; end // CF<-0
          else if (q_stc) begin eflags<=eflags | 32'h0000_0001;  flags_we=1'b0; end // CF<-1
          else if (q_cmc) begin eflags<=eflags ^ 32'h0000_0001;  flags_we=1'b0; end // CF<-~CF
          else begin
            unique case (q_kind)
              K_ALU: begin
                if (q_is_lea) gpr[q_dst_reg]<=q_ea;
                else if (q_is_pop && q_mem_write) begin
                  // POP m: stack value (mem_load_data) -> memory dest; ESP += w.
                  do_store=1'b1; do_retire=1'b0;
                end else if (q_is_pop) begin
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_dst_reg!=R_ESP) gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                end else if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(dst_cur, alu_out, q_w, q_dst_high8);
              end

              K_SHIFT: begin
                // count masked to 0 -> NO flag change, NO value change (QEMU).
                if (sh_cnt==6'd0) begin
                  flags_we=1'b0;
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                end else begin
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                  else gpr[q_dst_reg]<=reg_merge(dst_cur, sh_out, q_w, q_dst_high8);
                  begin
                    logic [31:0] fl; logic ofb;
                    fl=eflags;
                    if (q_shrot inside {3'd4,3'd5,3'd6,3'd7}) begin
                      // SHL/SHR/SAR: SF/ZF/PF from result, AF=0, CF & OF per QEMU
                      // (CC_DST=result, CC_SRC=shm1): OF = MSB(shm1) ^ MSB(result).
                      fl=eflags & 32'hFFFF_F72A;
                      fl[0]=sh_cfout; fl[2]=parity8(sh_out[7:0]); fl[4]=1'b0;
                      fl[6]=(wmask(sh_out,q_w)==32'd0); fl[7]=sbit(sh_out,q_w);
                      fl[11]=sbit(sh_shm1,q_w) ^ sbit(sh_out,q_w);
                      fl[1]=1'b1;
                    end else begin
                      // ROL/ROR/RCL/RCR: only CF and OF change.
                      unique case (q_shrot)
                        3'd0: ofb = sbit(sh_out,q_w) ^ sh_out[0];               // ROL: MSB^LSB(res)
                        3'd1: ofb = sbit(sh_out,q_w) ^ sbit2(sh_out,q_w);       // ROR: MSB^(MSB-1)(res)
                        default: ofb = sbit(sh_val,q_w) ^ sbit(sh_out,q_w);     // RCL/RCR: MSB(src)^MSB(res)
                      endcase
                      fl[0]=sh_cfout; fl[11]=ofb; fl[1]=1'b1;
                    end
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_SHLDRD: begin
                logic [5:0] cnt; logic [31:0] r, shm1;
                cnt = q_shift_cl ? {1'b0,gpr[R_ECX][4:0]} : {1'b0,q_shift_imm};
                if (cnt==6'd0) flags_we=1'b0;
                else begin
                  r = shld_result(q_shrd, dst_cur, reg_read(q_src_reg,q_w,1'b0), cnt, q_w);
                  // shm1 = dst shifted by (count-1) (same direction) = QEMU CC_SRC.
                  shm1 = q_shrd ? (wmask(dst_cur,q_w) >> (cnt-6'd1))
                                : wmask(wmask(dst_cur,q_w) << (cnt-6'd1), q_w);
                  gpr[q_dst_reg]<=reg_merge(dst_cur, r, q_w, 1'b0);
                  begin logic [31:0] fl;
                    fl=eflags & 32'hFFFF_F72A;
                    fl[0]=shld_cf(q_shrd, dst_cur, cnt, q_w); fl[2]=parity8(r[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(r,q_w)==32'd0); fl[7]=sbit(r,q_w);
                    fl[11]=sbit(shm1,q_w)^sbit(r,q_w); fl[1]=1'b1;
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_MULDIV: begin
                logic [31:0] srcv;
                srcv = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,q_src_high8);
                unique case (q_md)
                  3'd4: begin // MUL (unsigned)
                    logic [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p={48'd0, ({8'd0,gpr[R_EAX][7:0]}*{8'd0,srcv[7:0]})};
                    else if (q_w==3'd2) p={32'd0, ({16'd0,gpr[R_EAX][15:0]}*{16'd0,srcv[15:0]})};
                    else                p={32'd0,gpr[R_EAX]}*{32'd0,srcv};
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=(p[15:8]!=8'd0);  gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=(p[31:16]!=16'd0);
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=(p[63:32]!=32'd0); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    // QEMU compute_all_mul: ZF/SF/PF from low result, AF=0, CF=OF=ovf
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd5: begin // IMUL one-operand (signed)
                    logic signed [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p=$signed({{8{srcv[7]}},srcv[7:0]}) * $signed({{8{gpr[R_EAX][7]}},gpr[R_EAX][7:0]});
                    else if (q_w==3'd2) p=$signed({{16{srcv[15]}},srcv[15:0]}) * $signed({{16{gpr[R_EAX][15]}},gpr[R_EAX][15:0]});
                    else                p=$signed(srcv) * $signed(gpr[R_EAX]);
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=($signed(p)!=$signed({{56{p[7]}},p[7:0]}));   gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=($signed(p)!=$signed({{48{p[15]}},p[15:0]}));
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=($signed(p)!=$signed({{32{p[31]}},p[31:0]})); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd6: begin // DIV
                    if (q_w==3'd1) begin
                      logic [15:0] num; logic [15:0] qq, rr;
                      num=gpr[R_EAX][15:0]; qq=num/{8'd0,srcv[7:0]}; rr=num%{8'd0,srcv[7:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic [31:0] num,qq,rr;
                      num={gpr[R_EDX][15:0],gpr[R_EAX][15:0]}; qq=num/{16'd0,srcv[15:0]}; rr=num%{16'd0,srcv[15:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic [63:0] num,qq,rr;
                      num={gpr[R_EDX],gpr[R_EAX]}; qq=num/{32'd0,srcv}; rr=num%{32'd0,srcv};
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                  default: begin // IDIV /7
                    if (q_w==3'd1) begin
                      logic signed [15:0] num,den,qq,rr;
                      num=$signed(gpr[R_EAX][15:0]); den=$signed({{8{srcv[7]}},srcv[7:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic signed [31:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX][15:0],gpr[R_EAX][15:0]}); den=$signed({{16{srcv[15]}},srcv[15:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic signed [63:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX],gpr[R_EAX]}); den=$signed({{32{srcv[31]}},srcv});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                endcase
              end

              K_IMUL2: begin
                logic [31:0] s1,s2,lo; logic ov; logic [31:0] fl;
                s1 = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,1'b0);
                s2 = q_imul_3op ? q_imul_imm : reg_read(q_dst_reg,q_w,1'b0);
                if (q_w==3'd2) begin logic signed [31:0] pp;
                  pp=$signed({{16{s1[15]}},s1[15:0]})*$signed({{16{s2[15]}},s2[15:0]});
                  lo={16'd0,pp[15:0]};
                  gpr[q_dst_reg]<=reg_merge(dst_cur, {16'd0,pp[15:0]}, q_w, 1'b0);
                  ov=(pp!=$signed({{16{pp[15]}},pp[15:0]}));
                end else begin logic signed [63:0] pp; pp=$signed(s1)*$signed(s2);
                  lo=pp[31:0];
                  gpr[q_dst_reg]<=reg_merge(dst_cur, pp[31:0], q_w, 1'b0);
                  ov=(pp!=$signed({{32{pp[31]}},pp[31:0]}));
                end
                // QEMU CC_OP_MUL: ZF/SF/PF from low result, AF=0, CF=OF=ov.
                fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                fl[0]=ov; fl[11]=ov; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                eflags<=fl;
                flags_we=1'b0;
              end

              K_EXT: begin
                logic [31:0] s,r;
                s = q_mem_read ? mem_load_data : reg_read(q_src_reg, q_ext_srcw, q_src_high8);
                if (q_ext_srcw==3'd1) r = q_ext_signed ? {{24{s[7]}},s[7:0]} : {24'd0,s[7:0]};
                else                  r = q_ext_signed ? {{16{s[15]}},s[15:0]} : {16'd0,s[15:0]};
                // Destination width follows the operand-size: a 0x66-prefixed
                // MOVZX/MOVSX (66 0F B6/B7/BE/BF) writes a 16-bit register and
                // must PRESERVE [31:16]; the unprefixed form writes the full 32.
                gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], r, q_w, 1'b0);
              end

              K_SETCC: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {31'd0,cond_true(q_cc,eflags)}, 3'd1, q_dst_high8);
                flags_we=1'b0;
              end

              K_BITTEST: begin
                logic [4:0] idx; logic bv; logic [31:0] cur,res;
                // Register-direct / immediate bit index is taken modulo the
                // operand size: mod 16 for a 0x66-prefixed (16-bit) operand,
                // mod 32 otherwise. (Memory-operand bit-string forms, which use
                // the full index to address a different byte, are not decoded
                // here — they HALT — so masking the index is correct for all
                // forms reaching this block.)
                cur=wmask(dst_cur,q_w);
                idx = q_bit_imm ? q_imm[4:0] : reg_read(q_src_reg,3'd4,1'b0)[4:0];
                if (q_w==3'd2) idx = {1'b0, idx[3:0]};   // mod 16
                bv = cur[idx];
                unique case (q_bit_op)
                  3'd5: res=cur | (32'd1<<idx);
                  3'd6: res=cur & ~(32'd1<<idx);
                  3'd7: res=cur ^ (32'd1<<idx);
                  default: res=cur;
                endcase
                // Modify forms (BTS/BTR/BTC) write the destination at operand
                // width, preserving [31:16] for the 16-bit form.
                if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], res, q_w, 1'b0);
                begin logic [31:0] fl; fl=eflags; fl[0]=bv; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_BITSCAN: begin
                logic [31:0] s, idx; logic zero; int hi;
                // Operand-size aware: a 0x66-prefixed BSF/BSR (66 0F BC/BD)
                // operates on the low 16 bits, computes ZF from [15:0], and
                // writes a 16-bit destination index preserving [31:16].
                s = wmask(q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0), q_w);
                hi = (q_w==3'd2) ? 15 : 31;
                zero=(s==32'd0); idx=32'd0;
                if (!q_shrd) begin for (int i=hi;i>=0;i--) if (s[i]) idx=i[31:0]; end // BSF lowest
                else         begin for (int i=0;i<=hi;i++) if (s[i]) idx=i[31:0]; end // BSR highest
                if (!zero) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], idx, q_w, 1'b0);  // dest unchanged on src==0 (QEMU)
                // QEMU sets CC_OP_LOGIC with CC_DST = the SOURCE operand:
                //   ZF=(src==0) [defined]; SF=MSB(src); PF=parity(src); CF=OF=AF=0.
                begin logic [31:0] fl; fl=eflags & 32'hFFFF_F72A;
                  fl[0]=1'b0; fl[2]=parity8(s[7:0]); fl[4]=1'b0;
                  fl[6]=zero; fl[7]=sbit(s,q_w); fl[11]=1'b0; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_XCHG: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else begin
                  logic [31:0] a,b;
                  a=reg_read(q_dst_reg,q_w,q_dst_high8); b=reg_read(q_src_reg,q_w,q_src_high8);
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], b, q_w, q_dst_high8);
                  gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], a, q_w, q_src_high8);
                end
                flags_we=1'b0;
              end

              K_BSWAP: begin logic [31:0] v; v=gpr[q_dst_reg];
                gpr[q_dst_reg]<={v[7:0],v[15:8],v[23:16],v[31:24]}; end

              K_CONV: begin
                if (!q_conv_cdq) begin
                  if (q_w==3'd2) gpr[R_EAX]<={gpr[R_EAX][31:16], {8{gpr[R_EAX][7]}}, gpr[R_EAX][7:0]};
                  else           gpr[R_EAX]<={{16{gpr[R_EAX][15]}}, gpr[R_EAX][15:0]};
                end else begin
                  if (q_w==3'd2) gpr[R_EDX]<={gpr[R_EDX][31:16], {16{gpr[R_EAX][15]}}};
                  else           gpr[R_EDX]<={32{gpr[R_EAX][31]}};
                end
              end

              K_STKMISC: begin
                unique case (q_sm)
                  SM_LAHF: gpr[R_EAX]<={gpr[R_EAX][31:16], eflags[7:0], gpr[R_EAX][7:0]};
                  SM_SAHF: begin logic [31:0] fl; fl=eflags;
                    fl[7]=gpr[R_EAX][15]; fl[6]=gpr[R_EAX][14]; fl[4]=gpr[R_EAX][12];
                    fl[2]=gpr[R_EAX][10]; fl[0]=gpr[R_EAX][8]; fl[1]=1'b1; eflags<=fl; end
                  SM_PUSHF: begin do_store=1'b1; do_retire=1'b0; end
                  SM_POPF: begin
                    // EFLAGS <- [ESP], USER-MODE mask: status flags + DF/TF/AC/
                    // ID/NT writable; IF/IOPL/VM/RF preserved (QEMU CPL=3 popf).
                    // writable = CF|PF|AF|ZF|SF|TF|DF|OF|NT|AC|ID = 0x244DD5.
                    eflags<=((mem_load_data & 32'h0024_4DD5) |
                             (eflags & ~32'h0024_4DD5)) | 32'h0000_0002;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  // LEAVE: ESP<-EBP (full, stack-addr width), then pop (E)BP.
                  // A 0x66 LEAVE pops a 16-bit BP (preserve EBP[31:16]) and the
                  // stack slot is 2 bytes wide, so ESP = old EBP + 2.
                  SM_LEAVE: begin
                    gpr[R_EBP]<=reg_merge(gpr[R_EBP], wmask(mem_load_data,q_w), q_w, 1'b0);
                    gpr[R_ESP]<=gpr[R_EBP]+{28'd0,q_w};
                  end
                  SM_PUSHA, SM_POPA: begin do_retire=1'b0; state<=S_USEQ; step<=4'd0; end
                  default: ;
                endcase
                flags_we=1'b0;
              end

              K_STR: begin
                // one element; with REP iterate via S_USEQ keeping pc fixed.
                logic [31:0] cx;
                logic        rep_active, last_iter, cmp_term, store_needed;
                cx = gpr[R_ECX];
                rep_active = (q_rep || q_repne);
                // ECX==0 degenerate REP: no element, just advance EIP, one record.
                if (rep_active && cx==32'd0) begin
                  // no memory effect; retire as a no-op (handled by do_retire below)
                  do_retire=1'b1; flags_we=1'b0; new_eip=next_eip;
                end else begin
                  // execute one element this cycle
                  store_needed = q_str_storedi; // MOVS/STOS write [EDI]
                  // update pointers / flags / regs for this element:
                  if (q_str_loadsi)  gpr[R_ESI]<=gpr[R_ESI]+str_step;
                  if (q_str_storedi) gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_str_scandi)  gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_st==ST_LODS) gpr[R_EAX]<=reg_merge(gpr[R_EAX], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_str_scandi) begin eflags<=str_flags; end
                  flags_we=1'b0;

                  if (rep_active) begin
                    cx = cx - 32'd1;
                    gpr[R_ECX]<=cx;
                    // termination: ECX reaches 0, or (REPE/REPNE) ZF condition.
                    cmp_term = 1'b0;
                    if (q_str_scandi) begin
                      if (q_rep)   cmp_term = (str_flags[6]==1'b0); // REPE: stop when ZF=0
                      if (q_repne) cmp_term = (str_flags[6]==1'b1); // REPNE: stop when ZF=1
                    end
                    last_iter = (cx==32'd0) || cmp_term;
                    // Each REP iteration is its OWN retire record at the same PC.
                    // We retire here and, if not last, re-enter at the same PC.
                    if (last_iter) new_eip = next_eip;
                    else           new_eip = q_pc;   // stay on the REP instruction
                  end else begin
                    new_eip = next_eip;
                  end

                  if (store_needed) begin do_store=1'b1; do_retire=1'b0; end
                  else do_retire=1'b1;

                  // latch pre-increment [EDI] + data for the store stage (EDI is
                  // being incremented this cycle via NBA, so S_STORE must not
                  // re-read gpr[EDI]).
                  str_store_addr <= gpr[R_EDI];
                  str_store_data <= str_wdata;
                  // remember the eip we want after this element commit
                  str_next_eip <= new_eip;
                end
              end

              K_CTRL: begin
                unique case (q_ct)
                  CT_CALLREL, CT_CALLIND: begin do_store=1'b1; do_retire=1'b0; end
                  CT_JMPIND: new_eip = call_target;
                  // Near RET: pop the return IP at operand width. A 0x66 RET
                  // pops a 16-bit IP (EIP truncated to 16 bits) and ESP+=2.
                  CT_RETN: begin
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  CT_RETN_IMM: begin
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w}+{16'd0,q_ret_imm};
                  end
                  CT_LOOP, CT_LOOPE, CT_LOOPNE: begin
                    // 0x67 address-size: the count register is CX (low 16):
                    // decrement preserves ECX[31:16] and the taken test is CX!=0.
                    logic [31:0] cx; logic take; logic zero_after;
                    if (q_cnt16) begin
                      cx = {gpr[R_ECX][31:16], (gpr[R_ECX][15:0]-16'd1)};
                      zero_after = (cx[15:0]==16'd0);
                    end else begin
                      cx = gpr[R_ECX]-32'd1;
                      zero_after = (cx==32'd0);
                    end
                    gpr[R_ECX]<=cx;
                    take=~zero_after;
                    if (q_ct==CT_LOOPE)  take=take & eflags[6];
                    if (q_ct==CT_LOOPNE) take=take & ~eflags[6];
                    new_eip = take ? (next_eip+q_rel) : next_eip;
                    flags_we=1'b0;
                  end
                  CT_JECXZ: begin
                    logic cx_zero;
                    cx_zero = q_cnt16 ? (gpr[R_ECX][15:0]==16'd0) : (gpr[R_ECX]==32'd0);
                    new_eip=cx_zero?(next_eip+q_rel):next_eip; flags_we=1'b0;
                  end
                  default: ;
                endcase
              end
            endcase
          end

          // commit (non-store, non-microseq path)
          if (do_retire) begin
            if (flags_we) eflags<=flags_val;
            if (q_is_branch && q_branch_taken) eip<=next_eip+q_rel;
            else if (q_kind==K_STR) eip<=new_eip;  // string single (non-store) / ECX==0
            else eip<=new_eip;
            retire_valid<=1'b1;
            state<=S_FETCH;
          end else if (do_store) begin
            state<=S_STORE;
          end
        end

        // -------------------------------------------------------------------
        S_STORE: begin
          if (mem_ack) begin
            unique case (q_kind)
              K_CTRL: begin // CALL: push done, set EIP (width-aware ESP adjust)
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=call_target;
                retire_valid<=1'b1; state<=S_FETCH;
              end
              K_XCHG: begin // XCHG r/m,r mem: reg <- old mem
                gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], wmask(mem_load_data,q_w), q_w, q_src_high8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_FETCH;
              end
              K_STKMISC: begin // PUSHF
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=next_eip;
                retire_valid<=1'b1; state<=S_FETCH;
              end
              K_STR: begin // MOVS/STOS element stored
                eip<=str_next_eip; retire_valid<=1'b1; state<=S_FETCH;
              end
              default: begin
                if (q_is_push) gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w};
                if (q_is_pop)  gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};  // POP m
                if (q_writes_flags && q_kind==K_ALU) eflags<=flags_out;
                eip<=next_eip; retire_valid<=1'b1; state<=S_FETCH;
              end
            endcase
          end
        end

        // -------------------------------------------------------------------
        // S_USEQ: PUSHA / POPA micro-sequence (8 word transfers).
        S_USEQ: begin
          if (mem_ack) begin
            if (q_sm==SM_PUSHA) begin
              // push order: EAX,ECX,EDX,EBX,ESP(orig),EBP,ESI,EDI
              if (step==4'd7) begin
                gpr[R_ESP]<=pusha_esp - (32'd4*8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_FETCH;
              end else step<=step+4'd1;
            end else begin // POPA: pop EDI,ESI,EBP,(skip ESP),EBX,EDX,ECX,EAX
              unique case (step)
                4'd0: gpr[R_EDI]<=mem_rdata;
                4'd1: gpr[R_ESI]<=mem_rdata;
                4'd2: gpr[R_EBP]<=mem_rdata;
                4'd3: ; // skip ESP slot
                4'd4: gpr[R_EBX]<=mem_rdata;
                4'd5: gpr[R_EDX]<=mem_rdata;
                4'd6: gpr[R_ECX]<=mem_rdata;
                default: gpr[R_EAX]<=mem_rdata;
              endcase
              if (step==4'd7) begin
                gpr[R_ESP]<=gpr[R_ESP]+(32'd4*8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_FETCH;
              end else step<=step+4'd1;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FEXEC: x87 execute + commit. Updates fpr/ftop/fstat/fptag, sets
        // x87_touched_r, and either retires (advance EIP) or hands a memory
        // store to S_FSTORE. All arithmetic is bit-exact vs QEMU softfloat for
        // the corpus's normal operands (fpu_x87_pkg).
        // -------------------------------------------------------------------
        S_FEXEC: begin
          logic f_do_store, f_do_retire;
          logic [79:0] opnd_f;    // memory operand as floatx80 (read forms)
          logic [79:0] arg_b;     // right arithmetic operand (mem or st(i))
          logic [80:0] ar;        // {inexact, result}
          logic [82:0] arf;       // {ie, ze, inexact, result} from f_eval
          logic [2:0]  codes;
          logic [3:0]  xc;
          logic [79:0] st0v, stiv, resv;
          logic        inexact, cmp_ie;
          logic [1:0]  f_rc;      // rounding control (fctrl[11:10])
          logic        f_pc_bad;  // arithmetic requested under non-64-bit PC
          logic        f_is_arith;
          f_do_store=1'b0; f_do_retire=1'b1; inexact=1'b0; cmp_ie=1'b0;
          opnd_f = q_f_mem_read ? f_mem_as_float(f_mem80, q_f_mbytes) : 80'd0;
          st0v = fst(3'd0);
          stiv = fst(q_f_sti);
          f_rc = fctrl[11:10];

          // Precision control (PC = fctrl[9:8]) other than 11 (64-bit extended)
          // is a Tier-3 deferral: the datapath only implements full extended
          // precision, so rather than silently mis-rounding we HALT loudly on an
          // arithmetic op requested under PC != 11. (Data movement / compares /
          // constants are precision-independent and proceed normally.)
          f_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                       (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                       (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                       (q_fxop==FX_FSQRT);
          f_pc_bad = f_is_arith && (fctrl[9:8] != 2'b11);
          if (f_pc_bad) begin
            state<=S_HALT;
          end else
          unique case (q_fxop)
            // ---- loads (push) ----
            FX_FLD_M32, FX_FLD_M64, FX_FLD_M80: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= (q_fxop==FX_FLD_M80) ? f_mem80 : opnd_f;
            end
            FX_FILD_M16, FX_FILD_M32, FX_FILD_M64: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= f_mem_as_int(f_mem80, q_f_mbytes);
            end
            FX_FLDCONST: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= fconst(q_f_const);
            end
            FX_FLD_STI: begin
              // push a copy of ST(i). Note: i is evaluated on the CURRENT TOP,
              // before the push (QEMU pushes then ST0=old ST(i)).
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= stiv;
            end
            // ---- register moves / stack mgmt ----
            FX_FST_STI: begin
              fpr[fri(q_f_sti)] <= st0v; fptag[fri(q_f_sti)]<=1'b0;
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FXCH: begin
              fpr[ftop]          <= stiv;
              fpr[fri(q_f_sti)]  <= st0v;
            end
            FX_FFREE: begin fptag[fri(q_f_sti)]<=1'b1; end
            FX_FINCSTP: begin ftop<=ftop+3'd1; fstat<=fstat & ~16'h4700; end
            FX_FDECSTP: begin ftop<=ftop-3'd1; fstat<=fstat & ~16'h4700; end
            FX_FNOP: begin /* no state change */ end
            FX_FWAIT: begin /* no unmasked exception in corpus */ end
            FX_FNINIT: begin
              ftop<=3'd0; fctrl<=16'h037f; fstat<=16'h0000; fptag<=8'hFF;
            end
            FX_FNCLEX: begin fstat<=fstat & 16'h7f00; end
            FX_FLDCW:  begin fctrl<=f_mem80[15:0]; end
            // ---- sign / abs on ST0 ----
            FX_FABS: begin fpr[ftop]<= {1'b0, st0v[78:0]}; end
            FX_FCHS: begin fpr[ftop]<= {~st0v[79], st0v[78:0]}; end
            // ---- compares ----
            // FCOM/FCOMP/FCOMPP/FTST/FICOM are SIGNALING (#IA on any NaN);
            // FUCOM/FUCOMP/FUCOMPP are QUIET (#IA only on a signaling NaN).
            FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64: begin
              arg_b = (q_fxop==FX_FCOM_STI) ? stiv : opnd_f;
              codes = fcom_codes(st0v, arg_b);
              cmp_ie = fcom_ie(st0v, arg_b, 1'b1);     // signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FUCOM_STI: begin
              codes = fcom_codes(st0v, stiv);
              cmp_ie = fcom_ie(st0v, stiv, 1'b0);      // quiet
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FCOMPP: begin
              codes = fcom_codes(st0v, fst(3'd1));
              cmp_ie = fcom_ie(st0v, fst(3'd1), 1'b1); // FCOMPP signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              fptag[ftop]<=1'b1; fptag[ftop+3'd1]<=1'b1; ftop<=ftop+3'd2;
            end
            FX_FUCOMPP: begin
              codes = fcom_codes(st0v, fst(3'd1));
              cmp_ie = fcom_ie(st0v, fst(3'd1), 1'b0); // FUCOMPP quiet
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              fptag[ftop]<=1'b1; fptag[ftop+3'd1]<=1'b1; ftop<=ftop+3'd2;
            end
            FX_FTST: begin
              codes = fcom_codes(st0v, 80'd0);   // compare ST0 vs +0.0
              cmp_ie = fcom_ie(st0v, 80'd0, 1'b1);     // signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
            end
            FX_FXAM: begin
              xc = fxam_codes(st0v, fptag[ftop]);
              fstat <= (fstat & ~16'h4700) |
                       ({1'd0,xc[3]}<<14) | ({5'd0,xc[2]}<<10) |
                       ({6'd0,xc[1]}<<9)  | ({7'd0,xc[0]}<<8);
            end
            FX_FICOM_M16, FX_FICOM_M32: begin
              arg_b = f_mem_as_int(f_mem80, q_f_mbytes);
              codes = fcom_codes(st0v, arg_b);
              cmp_ie = fcom_ie(st0v, arg_b, 1'b1);     // FICOM signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            // ---- arithmetic ----
            // Each form selects (left,right) operands and calls f_eval, which
            // returns {ie, ze, inexact, result}. f_eval handles QEMU's explicit
            // special cases bit-exactly: x/0 -> signed Inf + ZE, 0/0 -> real-
            // indefinite QNaN + IE; otherwise the normal-operand datapath.
            FX_AR_ST0_STI: begin
              arf = f_eval(q_f_aluop, st0v, stiv, f_rc);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_AR_STI_ST0: begin
              // ST(i) op= ST0 : a=ST(i), b=ST0; sub/subr/div/divr direction per
              // QEMU helper_f{op}_STN_ST0 (which use ST(i) and ST0 in that order).
              arf = f_eval(q_f_aluop, stiv, st0v, f_rc);
              fpr[fri(q_f_sti)]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_AR_M32, FX_AR_M64: begin
              arf = f_eval(q_f_aluop, st0v, opnd_f, f_rc);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_AR_I16, FX_AR_I32: begin
              arf = f_eval(q_f_aluop, st0v, f_mem_as_int(f_mem80, q_f_mbytes), f_rc);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_FSQRT: begin
              // QEMU helper_fsqrt: if ST0 has its sign bit set (floatx80_is_neg),
              // clear the condition codes (0x4700) and set C2 (0x400) FIRST; then
              // floatx80_sqrt runs -> sqrt(-0)=-0 (no #IA); sqrt(negative finite)
              // = real-indefinite QNaN + #IA (IE). Positive operands take the
              // normal datapath (PE on inexact).
              if (st0v[79]) begin               // sign set: -finite / -0 / -NaN
                if (fx_is_neg(st0v) && !fx_is_nan(st0v)) begin
                  // negative non-zero (and not NaN): QNaN + IE, plus C2.
                  fpr[ftop]<= 80'hFFFFC000000000000000;
                  fstat <= (fstat & ~16'h4700) | 16'h0400 | 16'h0001;  // C2 + IE
                end else begin
                  // -0 (or -NaN): sqrt returns the operand; C2 set, no IE here.
                  ar = fx_sqrt(st0v, f_rc);
                  fpr[ftop]<=ar[79:0];
                  fstat <= (fstat & ~16'h4700) | 16'h0400;             // C2 only
                end
              end else begin
                ar = fx_sqrt(st0v, f_rc); inexact=ar[80];
                fpr[ftop]<=ar[79:0];
                if (inexact) fstat<=fstat | 16'h0020;
              end
            end
            // ---- memory stores: defer to S_FSTORE ----
            // The store VALUE and its exception flags depend only on ST0/fctrl
            // (stable across the store beats), so latch PE/IE (sticky) here at
            // dispatch. FST m80 / FNSTCW / FNSTSW m16 are exact (flags stay 0).
            FX_FST_M32, FX_FST_M64, FX_FST_M80,
            FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
            FX_FNSTCW, FX_FNSTSW_M: begin
              f_do_store=1'b1; f_do_retire=1'b0;
              if (fstore_ie)      fstat <= fstat | 16'h0001;   // IE (out-of-range FIST)
              else if (fstore_pe) fstat <= fstat | 16'h0020;   // PE (inexact store)
            end
            // ---- FNSTSW AX (writes AX, no memory) ----
            FX_FNSTSW_AX: begin
              gpr[R_EAX] <= {gpr[R_EAX][31:16],
                             (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
            end
            default: ;
          endcase

          // f_pc_bad already routed to S_HALT above (no retire); only commit the
          // EIP/retire when we actually executed the op.
          if (!f_pc_bad) begin
            if (f_do_retire) begin
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_FETCH;
            end else begin
              state<=S_FSTORE; f_step<=4'd0;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FSTORE: write the x87 store operand to memory over 1..3 bus beats,
        // then (for FSTP/FISTP) pop, advance EIP and retire. Memory contents are
        // not gate-compared, but stores are implemented faithfully.
        // -------------------------------------------------------------------
        S_FSTORE: begin
          if (mem_ack) begin
            // words needed: m16/cw/sw->1, m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              // last beat: apply pop and retire
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_FETCH; f_step<=4'd0;
            end else f_step<=f_step+4'd1;
          end
        end

        S_HALT: state<=S_HALT;
        default: state<=S_HALT;
      endcase
    end
  end

  // ===========================================================================
  // x87 store-operand value + exception flags (combinational). `fstore_val`
  // holds the word-aligned bytes to write; `fstore_pe`/`fstore_ie` carry the
  // precision (inexact) / invalid status QEMU latches on a rounding/overflowing
  // store (helper_fst*/helper_fist* -> merge_exception_flags). fstat is trace-
  // compared, so these must be set whenever QEMU would. Rounding honors RC.
  //   FST  m32/m64 : PE if the floatx80->float32/64 narrow rounds (inexact).
  //   FIST m16/m32/m64 : PE if the rounding-to-int loses a fraction; IE +
  //     integer-indefinite if the result is out of the destination's range.
  //   FST m80 / FNSTCW / FNSTSW m16 : exact, no exception.
  // ===========================================================================
  logic [79:0] fstore_val;
  logic        fstore_pe;
  logic        fstore_ie;
  always_comb begin
    logic [79:0] s0;
    logic [32:0] r32;
    logic [64:0] r64;
    logic [65:0] ri;             // {invalid, inexact, value}
    s0 = fpr[ftop];               // ST0
    r32 = 33'd0; r64 = 65'd0; ri = 66'd0;
    fstore_val = 80'd0; fstore_pe = 1'b0; fstore_ie = 1'b0;
    unique case (q_fxop)
      FX_FST_M32: begin
        r32 = fx_to_f32_ex(s0, fctrl[11:10]);
        fstore_val = {48'd0, r32[31:0]}; fstore_pe = r32[32];
      end
      FX_FST_M64: begin
        r64 = fx_to_f64_ex(s0, fctrl[11:10]);
        fstore_val = {16'd0, r64[63:0]}; fstore_pe = r64[64];
      end
      FX_FST_M80:  fstore_val = s0;
      FX_FIST_M16: begin
        ri = fx_to_int_ex(s0, 16, fctrl[11:10]);
        fstore_val = {64'd0, ri[15:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M32: begin
        ri = fx_to_int_ex(s0, 32, fctrl[11:10]);
        fstore_val = {48'd0, ri[31:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M64: begin
        ri = fx_to_int_ex(s0, 64, fctrl[11:10]);
        fstore_val = {16'd0, ri[63:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FNSTCW:   fstore_val = {64'd0, fctrl};
      FX_FNSTSW_M: fstore_val = {64'd0, (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
      default:     fstore_val = 80'd0;
    endcase
  end

  // ===========================================================================
  // Bus request generation (single combinational driver)
  // ===========================================================================
  always_comb begin
    mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
    unique case (state)
      S_FETCH: begin mem_req=1'b1; mem_addr=eip+{27'd0,fetch_word,2'b00}; end
      S_LOAD: begin
        mem_req=1'b1;
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))
          mem_addr=gpr[R_ESP];
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)
          mem_addr=gpr[R_EBP];     // LEAVE reads [EBP] (the saved frame ptr)
        else if (q_kind==K_STR) begin
          // load order: movs/lods/cmps -> [ESI]; scas -> [EDI]
          if (q_st==ST_SCAS) mem_addr=gpr[R_EDI];
          else               mem_addr=gpr[R_ESI];
        end else mem_addr=q_ea;
      end
      S_LOAD2: begin mem_req=1'b1; mem_addr=gpr[R_EDI]; end
      S_FLOAD: begin
        mem_req=1'b1; mem_addr=q_ea + {26'd0, f_step, 2'b00};   // q_ea + 4*f_step
      end
      S_FSTORE: begin
        mem_req=1'b1; mem_we=1'b1;
        mem_addr = q_ea + {26'd0, f_step, 2'b00};
        // the m80 third beat writes only 2 bytes; all others write a full word.
        if (q_f_mbytes==4'd10 && f_step==4'd2) mem_wstrb=4'b0011;
        else if (q_f_mbytes==4'd2)             mem_wstrb=4'b0011;   // m16 (cw/sw/int16)
        else                                   mem_wstrb=4'b1111;
        unique case (f_step)
          4'd0: mem_wdata = fstore_val[31:0];
          4'd1: mem_wdata = fstore_val[63:32];
          default: mem_wdata = {16'd0, fstore_val[79:64]};
        endcase
      end
      S_STORE: begin
        mem_req=1'b1; mem_we=1'b1;
        if (q_kind==K_STR) begin
          mem_wstrb=strb_of(q_w); mem_addr=str_store_addr; mem_wdata=str_store_data;
        end else begin
          mem_wstrb=st_strb; mem_addr=st_addr; mem_wdata=st_data;
        end
      end
      S_USEQ: begin
        mem_req=1'b1;
        if (q_sm==SM_PUSHA) begin
          mem_we=1'b1; mem_wstrb=4'b1111;
          mem_addr=pusha_esp - (32'd4*({28'd0,step}+32'd1));
          unique case (step)
            4'd0: mem_wdata=gpr[R_EAX];
            4'd1: mem_wdata=gpr[R_ECX];
            4'd2: mem_wdata=gpr[R_EDX];
            4'd3: mem_wdata=gpr[R_EBX];
            4'd4: mem_wdata=pusha_esp;     // original ESP
            4'd5: mem_wdata=gpr[R_EBP];
            4'd6: mem_wdata=gpr[R_ESI];
            default: mem_wdata=gpr[R_EDI];
          endcase
        end else begin // POPA: read ascending from ESP
          mem_we=1'b0; mem_addr=gpr[R_ESP] + (32'd4*{28'd0,step});
        end
      end
      default: ;
    endcase
  end

  // capture original ESP at the cycle we enter PUSHA's S_USEQ.
  always_ff @(posedge clk) begin
    if (state==S_EXEC && q_kind==K_STKMISC && q_sm==SM_PUSHA) pusha_esp<=gpr[R_ESP];
  end

  // ===========================================================================
  // Lint sinks
  // ===========================================================================
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, mem_rdata[0], pfx_lock, pfx_seg, pfx_addr, q_imul_3op,
                   q_str_storedi};
  // verilator lint_on UNUSED

endmodule : intcore
