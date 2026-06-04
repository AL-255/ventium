// core/core.sv — the Ventium integer/pipeline spine (R1 modularization,
// docs/rtl-refactor-plan.md). Renamed from intcore.sv: it now wires the
// extracted blocks (decode / issue_uv / ventium_alu_pkg / ventium_decode_pkg /
// fpu_x87_pkg) and runs the pipeline FSM + retire/DPI point. Functional spine:
// single-issue, in-order, multi-cycle integer core (PLAN.md §7,
// docs/m2-isa-spec.md), diff-clean vs QEMU user-mode.
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

module core
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
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

    // M4: when high, the core's fast path may issue two simple instructions per
    // clock (dual U/V issue) and reports pipe/paired for the cycle trace. When
    // low (the M1/M2/M3 functional gates), the fast path retires ONE instruction
    // per clock — architecturally identical, no pairing — so the func traces are
    // bit-for-bit unaffected by the pipeline. Tied 0 by default (lint-safe).
    input  logic        cycle_mode,

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
    output logic [79:0] retire_st4, retire_st5, retire_st6, retire_st7,

    // ------------------------------------------------------------------------
    // M4 cycle-trace attribution (docs/m4-pipeline-spec.md "RTL cycle-trace
    // producer", trace-format §2.3). The dual-issue pipeline raises these in the
    // SAME clock as retire_valid, conveying which pipe each retiring instruction
    // issued to and whether it issued paired. A paired issue retires TWO
    // instructions in one clock: retire_valid+retire2_valid both high, the U
    // insn carries retire_pipe=U/paired=0 and the V insn retire2_pipe=V/paired=1.
    // ventium_top turns each high retire(2)_valid into a vtm_retire(+_cycle) call.
    // pipe encoding: 0=U, 1=V, 2=none. (Func mode ignores all of this.)
    // ------------------------------------------------------------------------
    output logic        retire_pipe_valid,   // primary retirement carries pipe info
    output logic [1:0]  retire_pipe,         // 0=U 1=V 2=none for the primary insn
    output logic        retire_paired,       // primary insn issued paired (always U=0 here)

    output logic        retire2_valid,       // a SECOND insn retired this same clock
    output logic [31:0] retire2_pc,
    output arch_state_t retire2_state,
    output logic [1:0]  retire2_pipe,        // pipe for the second insn (V=1)
    output logic        retire2_paired       // second insn paired with the first (1)
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
  typedef enum logic [4:0] {
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_LOAD2, S_EXEC, S_STORE, S_USEQ, S_HALT,
    S_FLOAD, S_FEXEC, S_FSTORE,
    S_PF, S_PIPE
  } state_e;
  state_e state;

  localparam int IWORDS = 4;
  logic [7:0]  ibuf [16];
  logic [2:0]  fetch_word;

  // ===========================================================================
  // M4 dual-issue fast-path pipeline state (docs/m4-pipeline-spec.md §"How to
  // evolve the core"). A 32-byte prefetch buffer feeds a 2-wide decode + pairing
  // checker; simple/pairable instructions execute through it at up to 2/clock
  // with AGI interlock + a 256-entry/4-way BTB & 2-bit predictor. Anything the
  // fast path does not recognise falls back to the proven multi-cycle FSM
  // (S_FETCH..) so functional behaviour is preserved exactly.
  // ===========================================================================
  // 8 KB 2-WAY set-associative instruction cache (128 sets x 2 ways x 32 B line =
  // 256 lines), the P5 L1 I-cache geometry (Alpert & Avnon, docs/p5-timing-model.md).
  // M5 finding [med]: the oracle's I-cache is 2-WAY / 128-set / LRU
  // (verif/qemu-plugins/p5trace.c:61-65 L1_SETS=128 L1_WAYS=2, l1_access 2-way
  // LRU); a DIRECT-MAPPED I-cache gives a DIFFERENT hit/miss SEQUENCE for any
  // conflict-prone or partially-resident working set (wrong-way / replacement
  // divergence). The I-cache must use the SAME associativity/index/tag/LRU as the
  // oracle (and as the RTL D-cache) so the miss sequence — not just the aggregate
  // — agrees. set = addr[11:5] (128 sets), tag = addr[31:12] (20 bits). The fast
  // path decodes combinationally out of the cache; a miss triggers a line fill
  // (8 word reads = imiss penalty) in S_PF, allocating the 2-way LRU victim.
  localparam int IC_SETS = 128;
  localparam int IC_LINE = 32;
  logic [7:0]  ic_data [IC_SETS][2][IC_LINE];
  logic [19:0] ic_tag  [IC_SETS][2];   // addr[31:12]
  logic        ic_val  [IC_SETS][2];
  logic        ic_lru  [IC_SETS];      // 2-way LRU: way most-recently-used (== D$)
  logic [31:0] pf_fill_addr;         // line base currently being filled
  logic        pf_fill_way;          // 2-way victim way chosen for the fill
  logic [2:0]  pf_word;              // refill word counter (8 words = 32 bytes)

  // BTB: 64 sets x 4 ways, 2-bit saturating counters (Alpert & Avnon / AP-500).
  localparam int BTB_SETS = 64;
  localparam int BTB_WAYS = 4;
  logic [25:0] btb_tag [BTB_SETS][BTB_WAYS];   // pc/64
  logic [1:0]  btb_ctr [BTB_SETS][BTB_WAYS];   // 2-bit saturating
  logic        btb_val [BTB_SETS][BTB_WAYS];
  logic [1:0]  btb_rr  [BTB_SETS];             // round-robin replacement ptr

  // AGI tracking: gpr index written in the immediately-PREVIOUS issue clock.
  // -1 (bit8 set) = none. Updated each fast-path issue clock.
  logic [8:0]  agi_wr0, agi_wr1;     // up to two regs written last fast clock

  logic [2:0]  mispred_bubbles;      // remaining flush bubbles to burn

  // ===========================================================================
  // M5 cycle-accuracy state (docs/m5-cycle-spec.md). Two timing models, both
  // EMERGENT (real SM / real scoreboard), using the SAME geometry/penalty as the
  // p5model oracle (build/p5trace.so: imiss=8, dmiss=8, 8KB/2-way/32B, misalign
  // +3) so the cycle COMPONENTS agree, not a formula copied from the oracle.
  // ===========================================================================
  // Free-running core-clock counter (the timeline the FP scoreboard lives on).
  // Mirrors the TB's cyc = clock-count-at-retire; advances every clock.
  logic [31:0] core_cyc;

  // x87 FP latency/throughput scoreboard (p5model g.fp_ready). Holds the cycle at
  // which the x87 top-of-stack result of the most recent FP producer/rmw becomes
  // readable. A dependent FP consumer (fp_role>=2) must stall until then; this is
  // what turns a dependent fadd chain into CPI~3 (lat 3) while independent FP
  // pipelines at throughput 1 (the latency is overlapped by other work).
  logic [31:0] fp_ready_cyc;

  // FP pipe OCCUPANCY hold (p5model pipe_free_at = issue + occ). An FP op holds
  // the in-order pipe for `occ` clocks: even a FOLLOWING INDEPENDENT integer op
  // cannot issue until the FP op's occupancy expires (fdiv occ 39, fmul occ 2,
  // fsqrt occ 70). This is DISTINCT from result latency (fp_ready_cyc), which
  // only stalls a dependent FP CONSUMER. fp_occ_pending marks "occupancy clocks
  // are being burned; commit+retire when stall_cnt reaches 0"; fp_issue_cyc is
  // the cycle occupancy began (so fp_ready = issue + lat is anchored correctly).
  logic        fp_occ_pending;
  logic [31:0] fp_issue_cyc;

  // L1 D-cache TIMING model: 8 KB / 2-way / 32 B line / 128 sets, LRU. Data still
  // comes from the BFM (mem_rdata); this only gates WHEN a load completes. A read
  // miss adds dmiss; a misaligned access adds +3 (AP-500). Matches p5_mem() +
  // l1_access() in verif/qemu-plugins/p5trace.c (read-allocate, 2-way LRU).
  localparam int DC_SETS = 128;
  logic [19:0] dc_tag [DC_SETS][2];   // addr/32/128
  logic        dc_val [DC_SETS][2];
  logic        dc_lru [DC_SETS];      // 2-way LRU: way most-recently-used
  // I-cache miss penalty (imiss=8) is materialised EMERGENTLY by the existing
  // S_PF line-fill (8 word reads = 8 clocks), so it needs no constant here.
  localparam logic [6:0] P5_DMISS = 7'd8;   // D-cache miss penalty (plugin arg)
  localparam logic [6:0] P5_MISALIGN = 7'd3;// misaligned data access (AP-500)

  // Deferred D-cache penalty (p5model g.pending_mem_pen): a load's miss/misalign
  // penalty is charged to the NEXT instruction's issue (the model defers the
  // data stall by one retire). We replicate that one-instruction defer so the
  // per-instruction cyc deltas line up with the oracle.
  logic [6:0]  pending_mem_pen;

  // Multi-clock stall countdowns used to MATERIALISE a penalty as real clocks
  // (so cyc = clock-count-at-retire grows by exactly the penalty). Only one is
  // ever non-zero at a time; S_PIPE burns them before issuing.
  logic [6:0]  stall_cnt;             // remaining stall clocks before next issue

  // ALU op encoding (ALU_ADD..ALU_NOT) lives in ventium_alu_pkg (imported above).
  // op-class enum (kind_e), micro-sequencer enums (smk_e/st_e/ctk_e), and the
  // x87 decode enum (fxop_e) live in ventium_decode_pkg (imported above).

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
  // x87 sub-op encoding (fxop_e: FX_*) lives in ventium_decode_pkg. The decoder
  // classifies each escape (D8..DF + ModR/M) into one of these and supplies the
  // addressing (d_f_mem_read/write + d_f_msize) and operand index (d_f_sti).
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

  // mfl() (ModR/M field length) lives in ventium_decode_pkg.

  // ===========================================================================
  // Prefix machine
  // ===========================================================================
  logic [3:0] pfx_len;
  logic       pfx_opsize, pfx_addr, pfx_seg, pfx_lock;
  logic [1:0] pfx_rep;          // 0 none, 2 F2, 3 F3
  logic [7:0] op0, op1;
  logic       two_byte;

  // is_prefix() lives in ventium_decode_pkg.

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

  // cond_true() (Jcc tttn condition eval) lives in ventium_decode_pkg.
  // Width helpers (wmask/sbit/sbit2/parity8) live in ventium_alu_pkg.

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

  // ALU result + EFLAGS (alu_result/flags_next) and the shift/rotate datapath
  // (shrot_result/shrot_cf, shld_result/shld_cf) live in ventium_alu_pkg.

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

  // Second retirement (paired V issue). In cycle mode only `pc` is compared, so
  // retire2_state mirrors the primary snapshot (well-formed, never gate-checked
  // for the V member); retire2_pc is registered at issue.
  logic [31:0] q_pc2;
  assign retire2_state = snap;
  assign retire2_pc = q_pc2;

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

  // Slow-path data-LOAD address (mirrors the S_LOAD bus-driver address selection)
  // so the sequential block can run the D-cache timing SM on it (M5 finding [med]).
  logic [31:0] slow_dmem_addr;
  always_comb begin
    if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
        (q_kind==K_STKMISC && q_sm==SM_POPF))      slow_dmem_addr = gpr[R_ESP];
    else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)  slow_dmem_addr = gpr[R_EBP];
    else if (q_kind==K_STR) begin
      if (q_st==ST_SCAS)                           slow_dmem_addr = gpr[R_EDI];
      else                                         slow_dmem_addr = gpr[R_ESI];
    end else                                       slow_dmem_addr = q_ea;
  end

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
  // M4/M5 fast-path decoder — extracted to the `decode` leaf module
  // (rtl/core/decode.sv), instantiated as u_decode / v_decode above. It decodes
  // the simple/pairable instruction subset (fpd_t producer); anything else
  // leaves d.simple=0 and the core falls back to the multi-cycle FSM.
  // ===========================================================================

  // second ALU operand for a fast-path ALU/mov insn: imm, or the source reg, or
  // a fixed 1 for INC/DEC (matching the slow path's b_op selection).
  function automatic logic [31:0] fp_bop(input fpd_t d);
    if (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) fp_bop = 32'd1;
    else if (d.use_imm) fp_bop = d.imm;
    else fp_bop = reg_read(d.src, 3'd4, 1'b0);
  endfunction

  // pairing checker — extracted to the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv), instantiated as u_issue near the decode instances.
  // It takes the U decode + V candidate decode and drives `pipe_pair_ok`.

  // icache presence: is the 32-byte line containing `addr` resident in EITHER way
  // of its set? (2-way, mirrors the oracle / the RTL D-cache lookup.)
  function automatic logic ic_present(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      ic_present = (ic_val[set][0] && ic_tag[set][0]==tag) ||
                   (ic_val[set][1] && ic_tag[set][1]==tag);
    end
  endfunction
  // which way holds the line (assumes ic_present(addr)); way 1 iff way0 misses.
  function automatic logic ic_hit_way(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      ic_hit_way = !(ic_val[set][0] && ic_tag[set][0]==tag);
    end
  endfunction
  // icache byte read (assumes ic_present(addr)): from whichever way hit.
  function automatic logic [7:0] ic_byte(input logic [31:0] addr);
    ic_byte = ic_data[addr[11:5]][ic_hit_way(addr)][addr[4:0]];
  endfunction

  // icache LRU update on a confirmed HIT (the line's set marks the hit way MRU).
  // Mirrors the oracle l1_access() hit path (s->lru = w) and the RTL D-cache
  // dc_access hit path, so the I-cache replacement SEQUENCE matches the oracle.
  task automatic ic_touch(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      for (int w=0; w<2; w++)
        if (ic_val[set][w] && ic_tag[set][w]==tag) ic_lru[set]<=w[0];
    end
  endtask

  // D-cache hit test (timing only): is the 32-byte line containing `addr`
  // resident in either way of its set? Mirrors p5model l1_access() lookup. Does
  // NOT mutate state (the allocate/LRU update is done in the sequential block on
  // a confirmed access, so the model is a true LRU SM, not a combinational peek).
  function automatic logic dc_hit(input logic [31:0] addr);
    logic [6:0]  set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      dc_hit = (dc_val[set][0] && dc_tag[set][0]==tag) ||
               (dc_val[set][1] && dc_tag[set][1]==tag);
    end
  endfunction

  // D-cache access: update LRU on a hit, else allocate the not-MRU way (2-way
  // LRU replacement, exactly p5model l1_access()). Called once per load access
  // from the sequential block (so it advances the real cache SM, emergent).
  task automatic dc_access(input logic [31:0] addr);
    logic [6:0]  set; logic [19:0] tag; logic hit; logic victim;
    begin
      set = addr[11:5]; tag = addr[31:12]; hit = 1'b0; victim = ~dc_lru[set];
      for (int w=0; w<2; w++)
        if (dc_val[set][w] && dc_tag[set][w]==tag) begin hit=1'b1; dc_lru[set]<=w[0]; end
      if (!hit) begin
        dc_val[set][victim]<=1'b1; dc_tag[set][victim]<=tag; dc_lru[set]<=victim;
      end
    end
  endtask

  // BTB lookup: predicted-taken iff a valid matching entry has counter>=2.
  function automatic logic btb_lookup(input logic [31:0] pc);
    logic [5:0]  set; logic [25:0] tag; logic hit;
    begin
      set = pc[5:0]; tag = pc[31:6]; hit = 1'b0; btb_lookup = 1'b0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin
          hit=1'b1; btb_lookup = (btb_ctr[set][w] >= 2'd2);
        end
    end
  endfunction

  // BTB update after a branch resolves (mirrors p5model btb_update): a hit
  // saturates its 2-bit counter toward taken/not-taken; a miss on a TAKEN
  // branch allocates a way (pseudo-random/round-robin replacement) with a
  // weakly-taken counter; a miss on a not-taken branch allocates nothing.
  task automatic btb_update_taken(input logic [31:0] pc, input logic taken);
    logic [5:0]  set; logic [25:0] tag; logic hit; logic [1:0] way;
    begin
      set = pc[5:0]; tag = pc[31:6]; hit = 1'b0; way = 2'd0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin hit=1'b1; way=2'(w); end
      if (hit) begin
        if (taken && btb_ctr[set][way]!=2'd3) btb_ctr[set][way]<=btb_ctr[set][way]+2'd1;
        if (!taken && btb_ctr[set][way]!=2'd0) btb_ctr[set][way]<=btb_ctr[set][way]-2'd1;
      end else if (taken) begin
        btb_val[set][btb_rr[set]]<=1'b1;
        btb_tag[set][btb_rr[set]]<=tag;
        // first-taken => STRONGLY taken (ctr=3), matching the p5model oracle
        // (plugin/p5model.c:371 's->ctr[v]=3'). Allocating weakly-taken (2) would
        // diverge after a loop-exit not-taken: 2->1 (predict not-taken) re-warms a
        // mispredict on the next entry, whereas the oracle 3->2 stays predict-taken.
        btb_ctr[set][btb_rr[set]]<=2'd3;     // allocate strongly-taken (oracle)
        btb_rr[set]<=btb_rr[set]+2'd1;
      end
    end
  endtask

  // ===========================================================================
  // M4 fast-path combinational pipeline evaluation (S_PIPE). Decodes the U
  // instruction (and the V candidate at off+lenU) from the prefetch buffer,
  // runs the pairing checker + AGI detect, and computes each insn's post-commit
  // result with the SAME helpers the slow path uses. The sequential S_PIPE block
  // below consumes these to issue 1 or 2 instructions per clock.
  // ===========================================================================
  fpd_t        u_d, v_d;             // U insn + V candidate decodes
  logic        pipe_bytes_ok;        // U (+ V candidate) bytes resident in icache
  logic [31:0] pf_miss_fa;           // I-cache fill line address for a current miss
  logic        pf_miss;             // a fill-word-0 fetch is needed this S_PIPE clock
  logic        pipe_pair;            // U and V issue together this clock
  logic        v_bytes_ok;           // V candidate's full bytes resident in I-cache
  logic        pipe_agi;             // U has an AGI hazard (addr reg written last clk)
  logic        pipe_load_req;        // U is a register-base load (drives the bus)
  logic [2:0]  pipe_load_base;
  logic [31:0] u_alu, u_flags, u_sh, u_shm1; logic u_shcf;
  logic [31:0] v_alu, v_flags;
  logic [31:0] u_target, v_target;   // branch targets
  logic        u_pred_taken, v_pred_taken;
  logic        v_br_taken_eff;       // V branch taken using U's flags if forwarded
  logic [31:0] u_flags_eff;          // U's resulting flags (post-commit) for fwd
  logic [7:0]  ub [6];               // U decode bytes (icache, possibly 0 if cold)
  logic [7:0]  vb [6];               // V candidate decode bytes (at eip+lenU)

  // R1 phase-3: the fast-path decoder is now the `decode` leaf module
  // (rtl/core/decode.sv), instantiated once per slot (U + V candidate). The
  // byte windows are gathered combinationally below (U at eip, V at eip+lenU),
  // exactly as the in-line `fp_decode(...)` calls read them. u_d/v_d are driven
  // by the instances; everything downstream consumes them unchanged.
  always_comb begin
    for (int i=0;i<6;i++) ub[i] = ic_present(eip+i[31:0]) ? ic_byte(eip+i[31:0]) : 8'd0;
    for (int i=0;i<6;i++) vb[i] = ic_byte(eip+{28'd0,u_d.len}+i[31:0]);
  end

  decode u_decode (
      .ib0(ub[0]), .ib1(ub[1]), .ib2(ub[2]), .ib3(ub[3]), .ib4(ub[4]), .ib5(ub[5]),
      .iflags(eflags), .cycle_mode(cycle_mode), .uop(u_d)
  );
  decode v_decode (
      .ib0(vb[0]), .ib1(vb[1]), .ib2(vb[2]), .ib3(vb[3]), .ib4(vb[4]), .ib5(vb[5]),
      .iflags(eflags), .cycle_mode(cycle_mode), .uop(v_d)
  );

  // R1 phase-3: the pairing checker is now the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv). pipe_pair_ok is the bare can-pair RULES decision;
  // pipe_pair below ANDs in cycle_mode + V-bytes-resident exactly as before.
  logic pipe_pair_ok;
  issue_uv u_issue (.iu(u_d), .iv(v_d), .pair_ok(pipe_pair_ok));

  always_comb begin
    // M5 finding [med] (I-cache straddle): U is decodable+chargeable correctly iff
    // the line containing eip is resident AND, only when the instruction actually
    // crosses the 32-byte line boundary, the line containing its LAST byte too.
    // The oracle charges a second I-miss exactly when (vaddr&31)+size > 32
    // (verif/qemu-plugins/p5trace.c:428); it must NOT pre-charge a second-line
    // miss for a short instruction near the line end. The 6-byte fast-path decode
    // window can read into the next line, so require that straddle line for a SAFE
    // decode whenever the window crosses the boundary, but use the real decoded
    // length to decide whether a straddle miss is genuinely charged.
    pipe_bytes_ok = ic_present(eip)
                    // window-straddle: need the next line present to decode safely
                    && (({1'b0,eip[4:0]} + 6'd5 < 6'd32) || ic_present(eip + 32'd5))
                    // instruction-straddle: its last byte's line must be resident
                    && (({1'b0,eip[4:0]} + {2'b0,u_d.len} <= 6'd32)
                        || ic_present(eip + {28'd0,u_d.len} - 32'd1));
    // V candidate sits right after U (decoded by the v_decode instance above,
    // from the vb[] byte window gathered at eip+lenU).

    // I-cache fill line address for a current miss (eip's line first, else the
    // decode-window straddle line, else the instruction-straddle line) and the
    // condition under which the S_PIPE miss branch fires THIS clock (so the bus
    // driver can issue the fill's word-0 read on the detection clock — removing
    // the wasted transition clock, finding [med] I-miss off-by-one).
    pf_miss_fa = !ic_present(eip)         ? eip
               : !ic_present(eip + 32'd5) ? (eip + 32'd5)
               : (eip + {28'd0,u_d.len} - 32'd1);
    pf_miss = (state==S_PIPE) && (stall_cnt==7'd0) && !pipe_bytes_ok;

    // AGI: a base/index reg used by U was written in the IMMEDIATELY-preceding
    // fast-path issue clock (tracked in agi_wr0/agi_wr1; bit8=none).
    pipe_agi = 1'b0;
    if (u_d.addr_mask != 8'd0) begin
      if (!agi_wr0[8] && u_d.addr_mask[agi_wr0[2:0]]) pipe_agi=1'b1;
      if (!agi_wr1[8] && u_d.addr_mask[agi_wr1[2:0]]) pipe_agi=1'b1;
    end

    // pairing decision: V can pair only when U leads, no hazards, AND the V
    // candidate's FULL bytes are resident in the I-cache. A V branch can pair (it
    // fills V); a U branch never leads a pair (pairs_first=0).
    //
    // M5 (control-flow correctness): the V candidate is decoded combinationally
    // from ic_byte(), which returns whatever is in the array even for a NON-RESIDENT
    // line. If the V instruction STRADDLES into a cold line, its decode (opcode /
    // displacement / immediate) uses stale bytes — and a stale Jcc would be
    // mispaired and resolved with a wrong target/decode, diverging from the oracle's
    // instruction stream (reproduced: a `test(U); jz(V)` where the jz at offset 31
    // straddles a cold next line was resolved not-taken vs the oracle's taken). So
    // require the V instruction's first byte AND its last byte to be in resident
    // lines before pairing; otherwise V is not paired this clock — it becomes the
    // next U, the cold line fills via S_PF, and it issues with correct bytes.
    v_bytes_ok = ic_present(eip + {28'd0,u_d.len}) &&
                 ic_present(eip + {28'd0,u_d.len} + {28'd0,v_d.len} - 32'd1);
    pipe_pair = cycle_mode && v_bytes_ok && pipe_pair_ok;

    pipe_load_req  = (state==S_PIPE) && pipe_bytes_ok && u_d.simple &&
                     u_d.is_load && !pipe_agi && (mispred_bubbles==3'd0);
    pipe_load_base = u_d.base;

    // U datapath (reuse the shared helpers; results are bit-identical to slow).
    // INC/DEC use a fixed second operand of 1 (matching the slow path's b_op).
    u_alu   = alu_result(u_d.alu_op, reg_read(u_d.dst,3'd4,1'b0),
                         fp_bop(u_d), eflags[0]);
    u_flags = flags_next(u_d.alu_op, reg_read(u_d.dst,3'd4,1'b0),
                         fp_bop(u_d), u_alu, eflags, 3'd4);
    u_sh    = shrot_result(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                           {1'b0,u_d.shimm}, eflags[0], 3'd4);
    u_shm1  = (u_d.shimm==5'd0) ? reg_read(u_d.dst,3'd4,1'b0)
              : shrot_result(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                             {1'b0,u_d.shimm}-6'd1, eflags[0], 3'd4);
    u_shcf  = shrot_cf(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                       {1'b0,u_d.shimm}, eflags[0], 3'd4);
    u_target = (eip + {28'd0,u_d.len}) + u_d.rel;
    u_pred_taken = btb_lookup(eip);

    // V datapath (independent of U by the pairing rule, so reading the OLD gpr
    // state is correct for both).
    v_alu   = alu_result(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), eflags[0]);
    v_flags = flags_next(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), v_alu, eflags, 3'd4);
    v_target = ((eip + {28'd0,u_d.len}) + {28'd0,v_d.len}) + v_d.rel;
    v_pred_taken = btb_lookup(eip + {28'd0,u_d.len});

    // Flags forwarding U->V (the P5 cmp/dec/test + jcc pairing case): when the
    // U member writes EFLAGS, the paired V branch must see U's RESULT flags, not
    // the stale architectural eflags. Compute U's post-commit flags and use them
    // to evaluate a paired conditional V branch.
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
    v_br_taken_eff = v_d.br_cond ? cond_true(v_br_cc(v_d), u_flags_eff) : 1'b1;
  end

  // recover the 4-bit condition code of a V conditional branch from its decode
  // (Jcc rel8 opcode low nibble was consumed into br_cond/br_taken; we re-derive
  // it from the opcode byte stored implicitly). Since fp_decode does not keep the
  // raw cc, evaluate against the V's own br_taken when no forwarding is needed
  // and only override via this helper when U forwards flags.
  function automatic logic [3:0] v_br_cc(input fpd_t d);
    // Not reachable for non-branches; the cc is encoded in br fields. We stored
    // the architectural taken under the OLD flags; to re-evaluate under new
    // flags we need the cc. fp_decode is extended to carry it below.
    v_br_cc = d.cc;
  endfunction

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
      // M4 pipeline state.
      pf_fill_addr<=32'd0; pf_word<=3'd0; pf_fill_way<=1'b0;
      agi_wr0<=9'h100; agi_wr1<=9'h100; mispred_bubbles<=3'd0;
      // M5 cycle-accuracy state.
      core_cyc<=32'd0; fp_ready_cyc<=32'd0; pending_mem_pen<=7'd0; stall_cnt<=7'd0;
      fp_occ_pending<=1'b0; fp_issue_cyc<=32'd0;
      for (int s=0;s<DC_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;
      end
      retire2_valid<=1'b0; retire_pipe_valid<=1'b0;
      retire_pipe<=2'd0; retire_paired<=1'b0;
      retire2_pipe<=2'd0; retire2_paired<=1'b0;
      for (int s=0;s<BTB_SETS;s++) begin
        btb_rr[s]<=2'd0;
        for (int w=0;w<BTB_WAYS;w++) begin
          btb_val[s][w]<=1'b0; btb_tag[s][w]<=26'd0; btb_ctr[s][w]<=2'd0;
        end
      end
      for (int s=0;s<IC_SETS;s++) begin
        ic_lru[s]<=1'b0;
        ic_val[s][0]<=1'b0; ic_val[s][1]<=1'b0;
        ic_tag[s][0]<=20'd0; ic_tag[s][1]<=20'd0;
      end
    end else begin
      retire_valid <= 1'b0;
      retire2_valid <= 1'b0;
      retire_pipe_valid <= 1'b0;
      // x87-touched defaults low each cycle; only the x87 retire paths
      // (S_FEXEC / S_FSTORE) raise it, so the DPI x87 hook fires only for FPU
      // instructions. (ventium_top gates vtm_retire_x87 on this.)
      x87_touched_r <= 1'b0;

      // M5: advance the free-running core-clock counter (the timeline the FP
      // scoreboard + miss-stall countdowns live on). It tracks the TB's
      // cyc=clock-count-at-retire 1:1 (core_cyc is the count of completed clocks
      // before this edge; a retire on this edge stamps cyc=core_cyc+1).
      core_cyc <= core_cyc + 32'd1;

      unique case (state)
        S_RESET: begin fetch_word<=3'd0; state<=S_PIPE; end

        // -------------------------------------------------------------------
        // S_PF: fill ONE 32-byte icache line (the line covering pf_fill_addr) via
        // 8 word reads, then return to the fast path. A cold line pays this fill
        // penalty once; thereafter the line is resident and re-fetches are free,
        // so a hot loop body converges to its steady-state CPI (the same icache
        // amortisation the p5model uses).
        // -------------------------------------------------------------------
        S_PF: begin
          if (mem_ack) begin
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+0]<=mem_rdata[7:0];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+1]<=mem_rdata[15:8];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+2]<=mem_rdata[23:16];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+3]<=mem_rdata[31:24];
            if (pf_word==3'd7) begin
              pf_word<=3'd0;
              // allocate the chosen 2-way victim and mark it MRU (oracle l1_access
              // miss path: s->val[victim]=1; s->tag[victim]=tag; s->lru=victim).
              ic_tag[pf_fill_addr[11:5]][pf_fill_way]<=pf_fill_addr[31:12];
              ic_val[pf_fill_addr[11:5]][pf_fill_way]<=1'b1;
              ic_lru[pf_fill_addr[11:5]]<=pf_fill_way;
              state<=S_PIPE;
            end else pf_word<=pf_word+3'd1;
          end
        end

        // -------------------------------------------------------------------
        // S_PIPE: the dual-issue fast path. Each clock issues 0/1/2 simple
        // instructions through the U (and, when paired, V) pipe, with AGI
        // interlock + BTB/2-bit branch prediction. Non-simple insns or a dry
        // prefetch buffer hand control to the proven multi-cycle FSM / refill.
        // -------------------------------------------------------------------
        S_PIPE: begin
          if (stall_cnt!=7'd0) begin
            // M5: burn a materialised stall clock (D-cache miss / misalign /
            // FP-latency wait). No retirement; cyc = clock-count-at-retire thus
            // grows by exactly the penalty for the instruction that issues once
            // the countdown reaches 0. The stall clock writes nothing, so it
            // cannot create a phantom AGI hazard next clock.
            stall_cnt<=stall_cnt-7'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if (!pipe_bytes_ok) begin
            // icache miss on the line(s) covering the current insn: fill the
            // missing line (eip's line first, else the straddle line — the line of
            // either the decode-window end or the instruction's last byte). Each
            // fill = 8 word reads = imiss=8 clocks (the oracle penalty), emergent.
            // The 2-way victim is the not-MRU way (ic_lru^1), exactly the oracle's
            // `victim = s->lru ^ 1` (verif/qemu-plugins/p5trace.c:346).
            //
            // M5 finding [med] (I-miss off-by-one): the bus driver asserts the
            // fill's WORD-0 read in THIS detection clock (mem_addr = fill line base
            // when pf_miss is true), so this clock is productive — it captures word
            // 0 here and S_PF fetches words 1..7 (7 clocks). Total = 1 + 7 = 8
            // clocks = imiss exactly, with NO wasted transition clock (the old code
            // burned a non-fetching detection clock before the 8 fill clocks -> 9).
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][0]<=mem_rdata[7:0];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][1]<=mem_rdata[15:8];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][2]<=mem_rdata[23:16];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][3]<=mem_rdata[31:24];
            pf_fill_addr <= pf_miss_fa;
            pf_fill_way  <= ~ic_lru[pf_miss_fa[11:5]];
            pf_word<=3'd1; state<=S_PF;
          end else if (pending_mem_pen!=7'd0) begin
            // M5: a previous load's D-cache miss/misalign penalty is DEFERRED to
            // the next instruction (p5model g.pending_mem_pen folded into the next
            // insn's pipe_free_at, verif/qemu-plugins/p5trace.c:420). Materialise
            // it as real stall clocks so the next retire's cyc carries the +dmiss
            // delta exactly where the oracle places it. This clock + the stall_cnt
            // countdown together burn `pending_mem_pen` clocks before any issue.
            stall_cnt<=pending_mem_pen-7'd1;
            pending_mem_pen<=7'd0;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if (u_d.is_fp && u_d.fp_kind==FK_ARITH && fctrl[9:8]!=2'b11) begin
            // M5 finding [low]: an FK_ARITH (D8 reg-form fadd/fsub/fmul/fdiv) under
            // a non-extended precision control word (PC != 11) must NOT silently
            // compute the full extended-precision result (the datapath only
            // implements 64-bit extended). The slow path HALTs loudly in this case
            // (Tier-3 deferral, see f_pc_bad below); the fast path must do the same
            // so cycle-mode FP cannot diverge functionally from QEMU's
            // programmed-precision rounding. Default cw 0x037f has PC=11 (fine), so
            // the gate kernels never trip this; non-default-PC code HALTs.
            state<=S_HALT;
          end else if (u_d.is_fp) begin
            // M5: x87 FP fast path (cycle-mode whitelist). Functional execution
            // reuses the exact M3 helpers; the FP latency/throughput timing is
            // emergent from TWO distinct mechanisms, both mirroring the p5model
            // oracle (verif/qemu-plugins/p5trace.c):
            //   * RESULT LATENCY (fp_ready_cyc): a dependent FP consumer stalls
            //     until the producer's result is ready (issue+lat) -> dependent
            //     fadd chain CPI~3 (lat 3).
            //   * PIPE OCCUPANCY (fp_occ): the in-order pipe is held for `occ`
            //     clocks, so even a FOLLOWING INDEPENDENT op (integer or FP)
            //     cannot issue until the FP op's occupancy expires (oracle
            //     pipe_free_at=issue+occ; fdiv occ 39, fmul occ 2). This is what
            //     makes a single fdiv delay the integer work behind it.
            logic [31:0] dep_ready;
            logic [82:0] fp_arf;
            // RAW on the x87 top-of-stack: a consumer/rmw (fp_role>=2) must wait
            // until the most recent FP producer's result is ready (fp_ready_cyc).
            dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
            if (!fp_occ_pending && $signed(dep_ready - core_cyc) > 0) begin
              // stall until core_cyc reaches dep_ready (materialise the latency).
              stall_cnt <= 7'(dep_ready - core_cyc) - 7'd1;
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else if (!fp_occ_pending && u_d.fp_occ > 7'd1) begin
              // deps satisfied; begin burning the pipe-occupancy clocks. Record the
              // issue cycle so the result-latency scoreboard is anchored to issue
              // (not to the later retire). THIS clock is the issue clock (occupancy
              // cycle 1) and the eventual commit clock is occupancy cycle `occ`;
              // between them we burn occ-2 stall clocks, so the op retires exactly
              // `occ` clocks after issue (oracle pipe_free_at = issue + occ).
              fp_issue_cyc <= core_cyc;
              fp_occ_pending <= 1'b1;
              stall_cnt <= u_d.fp_occ - 7'd2;   // occ>=2 here; occ==2 => no stall
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else begin
              // ---- issue + commit the FP op (retires at issue+occ) -----------
              fp_arf = f_eval(u_d.fp_aluop, fst(3'd0), fst(u_d.fp_sti), fctrl[11:10]);
              unique case (u_d.fp_kind)
                FK_FLDC: begin
                  ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
                  fpr[ftop-3'd1]<=fconst(u_d.fp_sti);
                end
                FK_FLDSTI: begin
                  ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
                  fpr[ftop-3'd1]<=fst(u_d.fp_sti);
                end
                FK_ARITH: begin
                  fpr[ftop]<=fp_arf[79:0]; fstat<=f_arith_fstat(fstat, fp_arf);
                end
                FK_FSTP0: begin
                  fptag[ftop]<=1'b1; ftop<=ftop+3'd1;
                end
                FK_FXCH: begin
                  fpr[ftop]<=fst(u_d.fp_sti); fpr[fri(u_d.fp_sti)]<=fst(3'd0);
                end
                default: ;
              endcase
              // scoreboard: a producer/rmw publishes its result at ISSUE+lat. For
              // an occ-burned op the issue cycle was recorded above; for an occ==1
              // op issue==commit clock (core_cyc) — both anchor to the real issue.
              if (u_d.fp_role==3'd1 || u_d.fp_role==3'd3)
                fp_ready_cyc <= (fp_occ_pending ? fp_issue_cyc : core_cyc)
                                + {25'd0, u_d.fp_lat};
              fp_occ_pending <= 1'b0;
              // I-cache LRU: mark this fetched line MRU (2-way LRU, per the oracle
              // per-fetch l1_access). FP ops are 2 bytes (no straddle in practice).
              ic_touch(eip);
              eip<=eip + {28'd0,u_d.len};
              q_pc<=eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
              agi_wr0<=9'h100; agi_wr1<=9'h100;   // FP writes no GP reg
            end
          end else if (!u_d.simple) begin
            // hand this one instruction to the slow functional FSM. Clear the
            // AGI write-tracking: the slow op runs many cycles, so on return to
            // S_PIPE the LAST fast-path write is no longer "the immediately
            // preceding clock" and must not trigger a PHANTOM AGI stall (p5model
            // AGI checks reg_wcycle==issue-1, plugin/p5model.c:451).
            agi_wr0<=9'h100; agi_wr1<=9'h100;
            fetch_word<=3'd0; state<=S_FETCH;
          end else if (mispred_bubbles!=3'd0) begin
            // burn a misprediction flush bubble (no retirement this clock).
            mispred_bubbles<=mispred_bubbles-3'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // bubble writes nothing
          end else if (pipe_agi) begin
            // AGI 1-cycle interlock: stall this clock. The double-charge across
            // the immediately-following clock is prevented STRUCTURALLY by
            // clearing agi_wr0/agi_wr1 here (the stall clock writes nothing), so
            // next clock pipe_agi recomputes to 0 and the insn issues. This
            // charges the stall EVERY time the hazard exists (matching p5model's
            // per-issue reg_wcycle==issue-1 check, plugin/p5model.c:451) rather
            // than only the first time a given PC is seen -> correct for looped
            // AGI sites, where a fixed PC-suppressor would undercount stalls.
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // stall clock writes nothing
          end else begin
            // ---- ISSUE: commit U, and V if paired -------------------------
            logic [8:0]  w0, w1;
            logic        do_v;
            logic [31:0] post_eip;
            logic        u_is_br, redirect, u_taken;
            logic [31:0] redir_tgt;
            do_v   = pipe_pair;
            w0=9'h100; w1=9'h100;

            // ---- I-cache LRU: mark the fetched line(s) MRU (2-way LRU, mirroring
            // the oracle's per-instruction l1_access). U's line, U's straddle line
            // (only when it crosses the boundary), and the paired V's line are the
            // lines actually fetched this clock. Order matches the oracle (U then
            // its straddle then V).
            ic_touch(eip);
            if (({1'b0,eip[4:0]} + {2'b0,u_d.len}) > 6'd32)
              ic_touch(eip + {28'd0,u_d.len} - 32'd1);
            if (do_v) ic_touch(eip + {28'd0,u_d.len});

            // ---- U commit ----
            if (u_d.is_lea) begin
              gpr[u_d.dst]<=gpr[u_d.base];
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_load) begin
              gpr[u_d.dst]<=mem_rdata;
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              // M5: L1 D-cache TIMING. The load data still comes from the BFM
              // (mem_rdata, above); here we run the real 2-way LRU hit/miss SM and
              // DEFER any miss penalty (read-allocate +dmiss) / misalign (+3) to
              // the next instruction, exactly as p5_mem()/p5model does. A line
              // that misses is allocated now (dc_access) so re-references hit.
              dc_access(gpr[u_d.base]);
              begin
                logic [6:0] pen;
                pen = 7'd0;
                if (!dc_hit(gpr[u_d.base]))         pen = pen + P5_DMISS;
                if (gpr[u_d.base][1:0] != 2'b00)    pen = pen + P5_MISALIGN;
                pending_mem_pen <= pen;
              end
            end else if (u_d.is_shift) begin
              gpr[u_d.dst]<=u_sh;
              if (u_d.shimm!=5'd0) begin
                logic [31:0] fl;
                // SHL/SHR/SAL/SAR (shrot 4..7): SF/ZF/PF from result, AF=0,
                // CF & OF per QEMU (OF = MSB(shm1) ^ MSB(result)). Matches the
                // slow path's K_SHIFT block exactly (only this group reaches the
                // fast path; rotates fall back to the slow FSM).
                fl=eflags & 32'hFFFF_F72A;
                fl[0]=u_shcf; fl[2]=parity8(u_sh[7:0]); fl[4]=1'b0;
                fl[6]=(u_sh==32'd0); fl[7]=u_sh[31];
                fl[11]=u_shm1[31]^u_sh[31]; fl[1]=1'b1;
                eflags<=fl;
              end
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_branch || u_d.is_nop) begin
              // no register/flag write
            end else begin
              if (u_d.wreg) begin
                gpr[u_d.dst]<=u_alu;
                if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              end
              if (u_d.wflags) eflags<=u_flags;
            end

            // ---- V commit (paired) ----
            if (do_v) begin
              if (v_d.is_lea) begin
                gpr[v_d.dst]<=gpr[v_d.base];
                if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
              end else if (v_d.is_branch || v_d.is_nop) begin
                // V branch: handled via branch logic below
              end else begin
                if (v_d.wreg) begin
                  gpr[v_d.dst]<=v_alu;
                  if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
                end
                // a paired V that writes flags overrides U's flags (program
                // order: V is later). Only ALU/inc/dec reach here.
                if (v_d.wflags) eflags<=v_flags;
              end
            end

            // ---- branch resolution (U leads; or V branch when paired) -----
            // Determine the architectural taken decision + predicted target and
            // whether we mispredicted -> flush bubbles. The branch can be U
            // (unpaired) or the V member of a pair.
            u_is_br  = u_d.is_branch;
            u_taken  = 1'b0; redirect=1'b0; redir_tgt=32'd0;
            post_eip = eip + {28'd0,u_d.len} + (do_v ? {28'd0,v_d.len} : 32'd0);

            if (u_is_br) begin
              // U is the (sole) branch this clock.
              u_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
              redir_tgt = u_taken ? u_target : (eip + {28'd0,u_d.len});
              if (u_taken != u_pred_taken) begin
                mispred_bubbles <= 3'd3;     // U-pipe mispredict penalty
                redirect=1'b1;
              end else if (u_taken) redirect=1'b1;
              btb_update_taken(eip, u_taken);
            end else if (do_v && v_d.is_branch) begin
              // V member is a simple branch (e.g. a jcc paired into V). Use the
              // flags FORWARDED from U (cmp/dec/test + jcc pairing case).
              logic v_taken; logic [31:0] vpc;
              vpc = eip + {28'd0,u_d.len};
              v_taken = v_br_taken_eff;
              redir_tgt = v_taken ? v_target : (vpc + {28'd0,v_d.len});
              if (v_taken != v_pred_taken) begin
                // Mispredict penalty matches the oracle resolve_pending_branch
                // (verif/qemu-plugins/p5trace.c:402-403): an UNCONDITIONAL taken
                // jmp/call mispredict is P5_MISPREDICT_UNCOND=3 REGARDLESS of pipe
                // (the `!pend_cond` case is checked first); only a CONDITIONAL Jcc
                // in the V pipe pays P5_MISPREDICT_V=4. The old code charged 4 for
                // a V jmp too (now V-pairable per finding [med]) -> +1 over oracle.
                mispred_bubbles <= v_d.br_cond ? 3'd4 : 3'd3;
                redirect=1'b1;
              end else if (v_taken) redirect=1'b1;
              btb_update_taken(vpc, v_taken);
            end

            eip <= redirect ? redir_tgt : post_eip;
            agi_wr0<=w0; agi_wr1<=w1;

            // ---- retire records (cyc/pipe/paired emerge from the cadence) --
            q_pc <= eip;                       // primary (U) retire pc
            retire_valid <= 1'b1;
            retire_pipe_valid <= 1'b1;
            retire_pipe <= 2'd0;        // U
            retire_paired <= 1'b0;
            if (do_v) begin
              // GUARD: dual-issue (V retire) is CYCLE-MODE ONLY. retire2_state is
              // hardwired to the primary (U) `snap` and is NOT a valid post-commit
              // snapshot for the V instruction, so a paired V must never be emitted
              // in a state-checked (func) run. pipe_pair already ANDs cycle_mode;
              // this assertion locks that invariant so a future change that lets
              // pairing leak into func mode trips loudly instead of silently
              // comparing the wrong architectural state for the V member.
              // synopsys translate_off
              if (!cycle_mode) begin
                $error("core: paired V retire (do_v) in func mode (cycle_mode=0): retire2_state is U's snap, not the V insn's post-commit state");
              end
              // synopsys translate_on
              q_pc2 <= eip + {28'd0,u_d.len};   // V retire pc
              retire2_valid <= 1'b1;
              retire2_pipe  <= 2'd1;    // V
              retire2_paired<= 1'b1;
            end
            // After a redirect the next S_PIPE clock re-checks icache presence
            // (pipe_bytes_ok) and fills the target line via S_PF if cold.
          end
        end

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

          if (d_halt || d_unknown) begin
            // M5 finding [low]: in CYCLE mode the oracle emits a retire record for
            // the terminating `int 0x80` (it is a retired instruction to the TCG
            // plugin), so the RTL must too — otherwise the cycle trace is one
            // record short of the golden and compare.py reports a LENGTH MISMATCH
            // (harmless under the current gate, which ignores compare's exit code,
            // but it would fail a tightened gate that honored it). Emit ONE retire
            // for a genuine HALT syscall (d_halt) and THEN stop. d_unknown (an
            // out-of-scope opcode) stays a LOUD no-retire HALT — never a record, so
            // an unsupported opcode can never masquerade as a clean run. Func mode
            // keeps the M0/QEMU-gdbstub convention (no post-state row for the exit
            // syscall), so this extra retire is cycle-mode only and cannot perturb
            // the functional gates.
            if (cycle_mode && d_halt && !d_unknown) begin
              q_pc<=eip; retire_valid<=1'b1;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
            end
            state<=S_HALT;
          end
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
            // M5 finding [med] (D-cache state consistency): a SLOW-PATH data load
            // (displacement/SIB load, RMW source, string/stack load) must mutate
            // the D-cache timing model exactly like the oracle's p5_mem (which runs
            // l1_access for EVERY memory op, not just register-indirect loads). Do
            // the 2-way LRU access here and DEFER a read-miss/misalign penalty to
            // the next instruction (read-allocate), so a line warmed by a slow-path
            // access is later seen RESIDENT by a fast-path load (and vice-versa).
            // Gated on cycle_mode (func mode does no cycle accounting).
            if (cycle_mode) begin
              logic [31:0] la; logic [6:0] pen;
              la = slow_dmem_addr; pen = 7'd0;
              if (!dc_hit(la))           pen = pen + P5_DMISS;
              if (la[1:0] != 2'b00)      pen = pen + P5_MISALIGN;
              dc_access(la);
              pending_mem_pen <= pen;
            end
            if (q_kind==K_STR && q_st==ST_CMPS) state<=S_LOAD2;
            else state<=S_EXEC;
          end
        end
        S_LOAD2: begin
          if (mem_ack) begin
            mem_load_data2<=mem_rdata; state<=S_EXEC;
            // CMPS second operand [EDI] is also a data load -> D-cache access.
            if (cycle_mode) begin
              logic [6:0] pen; pen=7'd0;
              if (!dc_hit(gpr[R_EDI]))      pen = pen + P5_DMISS;
              if (gpr[R_EDI][1:0]!=2'b00)   pen = pen + P5_MISALIGN;
              dc_access(gpr[R_EDI]);
              pending_mem_pen <= pen;
            end
          end
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
            state<=S_PIPE;   // re-enter fast path
          end else if (do_store) begin
            state<=S_STORE;
          end
        end

        // -------------------------------------------------------------------
        S_STORE: begin
          if (mem_ack) begin
            // M5 finding [med]: a STORE mutates the D-cache (read-allocate write-back
            // allocates/updates LRU) but adds NO miss penalty (oracle p5_mem:
            // `if (!hit && !store) pending += dmiss` — stores skip the penalty). A
            // misaligned store still costs +3. Run the LRU SM so a line warmed by a
            // store is later seen RESIDENT by a load (the divergent-state bug).
            if (cycle_mode) begin
              logic [31:0] sa;
              sa = (q_kind==K_STR) ? str_store_addr : st_addr;
              dc_access(sa);
              if (sa[1:0] != 2'b00) pending_mem_pen <= pending_mem_pen + P5_MISALIGN;
            end
            unique case (q_kind)
              K_CTRL: begin // CALL: push done, set EIP (width-aware ESP adjust)
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=call_target;
                retire_valid<=1'b1; state<=S_PIPE;
              end
              K_XCHG: begin // XCHG r/m,r mem: reg <- old mem
                gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], wmask(mem_load_data,q_w), q_w, q_src_high8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end
              K_STKMISC: begin // PUSHF
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=next_eip;
                retire_valid<=1'b1; state<=S_PIPE;
              end
              K_STR: begin // MOVS/STOS element stored
                eip<=str_next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end
              default: begin
                if (q_is_push) gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w};
                if (q_is_pop)  gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};  // POP m
                if (q_writes_flags && q_kind==K_ALU) eflags<=flags_out;
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
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
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
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
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
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
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
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
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE; f_step<=4'd0;
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
      S_PF:    begin mem_req=1'b1; mem_addr={pf_fill_addr[31:5],5'd0}+{27'd0,pf_word,2'b00}; end
      S_PIPE:  begin
        // a register-base load issued this clock reads [base] combinationally.
        if (pipe_load_req) begin mem_req=1'b1; mem_addr=gpr[pipe_load_base]; end
        // I-cache miss detected this clock: fetch the fill line's WORD 0 NOW so the
        // detection clock is productive (finding [med] I-miss off-by-one). S_PF then
        // fetches words 1..7. mem_req for the load and the fill are mutually
        // exclusive: pf_miss => !pipe_bytes_ok => pipe_load_req is false.
        else if (pf_miss) begin mem_req=1'b1; mem_addr={pf_miss_fa[31:5],5'd0}; end
      end
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

endmodule : core
