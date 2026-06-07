// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// fpu/fpu_top.sv — x87 architectural STATE FILE
//                  (extracted from core.sv, R2; behaviour-preserving).
//
// PLAN.md §6.6 (x87 FPU) / IA-32 SDM Vol.1 (243190) ch.7 (x87 architecture).
// Key reference: Alpert & Avnon IEEE Micro 1993 p.6-8 (Fig.8 pipeline, Fig.9
// datapath, SIR, FXCH); Agner Fog P5 FP latency table.
//
// SCOPE (the R2 leaf, honest target): this module owns ONLY the x87
// architectural STATE — the 8x80-bit physical stack file fpr[8], the 3-bit TOP
// pointer (ftop), the 16-bit control word (fctrl), the 16-bit status word
// (fstat, condition codes + exception flags; TOP NOT overlaid here), and the
// 8-bit tag word (fptag, bit i = tag for fpr[i], 1=empty). Plus the synchronous
// reset (= FNINIT power-on: ftop=0/fctrl=0x037f/fstat=0/fptag=0xFF, fpr[]=0) and
// the ftop-relative st(i) read addressing (fst/fri).
//
// The DATAPATH (every floatx80 value: f_eval/fconst/apply_cmp/fcom_codes/
// fxam_codes/fx_sqrt/f_mem_as_*/f_arith_fstat/the fstore narrow) STAYS in the
// spine as fpu_x87_pkg calls — the spine computes each value and drives it onto
// this module's write-port data inputs; the module never computes a floatx80
// and never masks fstat. So is the M5 FP scoreboard (fp_ready_cyc/
// fp_occ_pending/fp_issue_cyc — the cycle model braided with integer issue), the
// FSM sequencing (S_FEXEC/S_FSTORE), and FNSTSW->gpr[EAX] (the spine reads
// fstat_o/ftop_o and writes the integer file). The fstat write port takes a
// FULLY-COMPUTED 16-bit value (the spine does ALL masking/merging/sticky-OR), so
// the trace overlay (retire_fstat = (fstat&~0x3800)|(ftop<<11)) + FNSTSW stay
// byte-identical.
//
// BIT-EXACT NBA SEMANTICS — the critical invariant. The original inline code
// writes fpr[ftop-1]/fptag[ftop-1] AND ftop<=ftop-1 in the SAME clock, all
// addressed by the PRE-edge (registered) ftop (NBA reads old ftop). This module
// reproduces that EXACTLY: every write index is computed from the REGISTERED
// `ftop` inside the same always_ff, and ftop itself is updated in that block, so
// "old-ftop" push (ftop-1) / pop (ftop) / sti (ftop+idx) addressing is preserved
// VERBATIM. The combinational read ports (st0..st7, rd_phys_top, rd_sti_data)
// mirror the registered fpr/ftop with ZERO added latency, so FXCH's two-slot
// swap (each slot reads the OTHER's pre-edge value) and fstore_val's fpr[ftop]
// read see the same PRE-edge state the inline reads did.
//
// WRITE PORTS — the two writer arms (the M5 cycle-mode FP fast path and the slow
// S_FEXEC/S_FSTORE FSM) are RUNTIME-EXCLUSIVE, so the spine ORs the per-arm
// drivers and at most ONE we_* (per category) asserts in any clock. The observed
// patterns never need both an fpr-pair AND a tag-pair the same clock; ftop moves
// by -1/+1/+2 or to absolute 0 (FNINIT). The write decode below is one block on
// the registered ftop, mirroring the inline NBA priority/parallelism EXACTLY.

module fpu_top (
    input  logic        clk,
    input  logic        rst_n,        // sync reset -> FNINIT power-on state

    // ---- READ PORTS (combinational, zero-cycle) ----
    output logic [79:0] st0, st1, st2, st3, st4, st5, st6, st7, // fpr[(ftop+i)]
    output logic [2:0]  ftop_o,       // current TOP (for FNSTSW->gpr in spine)
    output logic [15:0] fstat_o,      // RAW fstat (TOP NOT overlaid; spine overlays)
    output logic [15:0] fctrl_o,      // control word (spine reads RC/PC + FLDCW echo)
    output logic [7:0]  fptag_o,      // raw tag word (spine reads fptag[ftop] for FXAM)
    // physical ST0 read (datapath fstore_val needs fpr[ftop] directly):
    output logic [79:0] rd_phys_top,  // = fpr[ftop] (ST0 physical, for fstore_val)

    // ---- WRITE PORTS (spine drives at most one we_* per category per clock) ----
    // (1) PUSH: ftop--, fpr[ftop-1]<=push_data, fptag[ftop-1]<=0
    input  logic        we_push,
    input  logic [79:0] push_data,

    // (2) ARITH/UNARY at TOP: fpr[ftop]<=top_data
    input  logic        we_top,
    input  logic [79:0] top_data,
    // fstat full-16b replace; independent (co-fires with we_top, or alone for
    // compares). The spine has already done ALL masking/merge/sticky-OR.
    input  logic        we_fstat,
    input  logic [15:0] fstat_wval,

    // (3) WRITE ST(i) PHYSICAL: fpr[ftop+wsti_idx]<=wsti_data, and (only when
    //     wsti_clr_tag) fptag[ftop+wsti_idx]<=0. FST_STI clears the tag (the slot
    //     becomes valid); AR_STI_ST0 does NOT touch the tag (the inline arm only
    //     writes fpr[fri], leaving the tag word), so wsti_clr_tag distinguishes
    //     them and the byte-exactness of fptag is preserved.
    input  logic        we_sti,
    input  logic [2:0]  wsti_idx,
    input  logic [79:0] wsti_data,
    input  logic        wsti_clr_tag,

    // (4) FXCH 2-SLOT SWAP: fpr[ftop]<=fxch_a, fpr[ftop+fxch_idx]<=fxch_b
    //     (NO tag/ftop change)
    input  logic        we_fxch,
    input  logic [2:0]  fxch_idx,
    input  logic [79:0] fxch_a,        // -> fpr[ftop]
    input  logic [79:0] fxch_b,        // -> fpr[ftop+idx]

    // (5) POP: fptag[ftop]<=1, ftop<=ftop+1 (co-fires with we_sti/we_top/we_fstat)
    input  logic        we_pop,
    // (6) POP2 (FCOMPP/FUCOMPP): fptag[ftop]<=1, fptag[ftop+1]<=1, ftop<=ftop+2
    input  logic        we_pop2,

    // (7) FFREE: fptag[ftop+ffree_idx]<=1 (arbitrary tag set, no ftop)
    input  logic        we_ffree,
    input  logic [2:0]  ffree_idx,

    // (8) INCSTP/DECSTP: ftop +/- 1 (the fstat clear rides we_fstat)
    input  logic        we_incstp,
    input  logic        we_decstp,

    // (9) DIRECT scalar writes: fctrl<=fctrl_wval (FLDCW); FNINIT (full reset).
    input  logic        we_fctrl,
    input  logic [15:0] fctrl_wval,
    input  logic        we_fninit,

    // (10) M11 env-pointer latches. The FPU instruction pointer (FIP/FCS) latches
    // on every NON-control FP op; the data pointer (FDP/FDS) only on memory-operand
    // FP ops. These feed ONLY the FNSTENV/FNSAVE store image (read via *_o), NEVER
    // the graded trace pointer fields (which are constant 0 in both producers).
    input  logic        we_eptr,
    input  logic [31:0] eptr_fip,
    input  logic [15:0] eptr_fcs,
    input  logic        we_dptr,
    input  logic [31:0] dptr_fdp,
    input  logic [15:0] dptr_fds,
    output logic [31:0] fip_o,
    output logic [15:0] fcs_o,
    output logic [31:0] fdp_o,
    output logic [15:0] fds_o,
    // M11b: the 8 PHYSICAL registers flattened (fpr[0] in the low 80 bits), for the
    // FNSTENV/FNSAVE env-image FTW assembly + the FNSAVE ST-register slots.
    output logic [639:0] fpr_flat_o,

    // (11) M11b FLDENV/FRSTOR commit: reload CW/SW/TOP + the per-reg empty bits
    // (we_envld); FRSTOR additionally reloads the 8 physical registers (we_envregs).
    input  logic        we_envld,
    input  logic [15:0] env_fctrl,
    input  logic [2:0]  env_ftop,
    input  logic [15:0] env_fstat,    // raw (TOP bits already cleared)
    input  logic [7:0]  env_fptag,    // bit p = 1 (empty) iff loaded FTW field == 11
    input  logic        we_envregs,
    input  logic [639:0] env_fpr_flat, // fpr[0] in the low 80 bits (physical)

    // (12) +VEN_FP_PIPE delayed-arith commit: write fpr[wabs_idx] (ABSOLUTE phys
    // index, captured at issue so it is immune to ftop changes between issue and
    // the deferred commit) <= wabs_data, and fstat <= wabs_fstat (full replace,
    // already merged by the spine). Independent of we_top/we_sti/we_fstat — those
    // are NOT asserted for a pipelined arith op (its same-cycle commit is
    // suppressed). Applied LAST so a pipelined result wins a same-clock fstat race
    // only if the spine routed it here (it never co-asserts both for one op).
    input  logic        we_wabs,
    input  logic [2:0]  wabs_idx,
    input  logic [79:0] wabs_data,
    input  logic        we_wabs_fstat,
    input  logic [15:0] wabs_fstat
);

  // ---- the architectural state file (VERBATIM the inline declarations) -------
  // st(i) = fpr[(ftop+i)&7]. Push decrements TOP then writes; pop increments TOP
  // (leaving the stale value, so the trace's "empty" st-slots keep their last
  // contents — matches QEMU). fstat keeps the TOP field (bits[13:11]) ZERO
  // internally; the spine overlays ftop on read (mirrors helper_fnstsw). fptag
  // bit i = tag for fpr[i] (1=empty), drives FXAM's empty-detect + C1 sign.
  logic [79:0] fpr [8];
  logic [2:0]  ftop;
  logic [15:0] fctrl;        // control word; reset 0x037f
  logic [15:0] fstat;        // condition codes + exception flags; TOP not overlaid
  logic [7:0]  fptag;        // bit i = tag for fpr[i] (1=empty)
  // M11: FPU instruction/data pointers (env-image only; never the graded trace).
  // FOP is always 0 in this oracle, so it is not stored (hardwired 0 at emit).
  logic [31:0] fip, fdp;     // instruction-ptr offset / data-ptr offset
  logic [15:0] fcs, fds;     // code selector / data selector

  // ---- combinational read ports: mirror the registered fpr/ftop, ZERO latency.
  // These reflect PRE-edge state the same clock a posedge write below updates it
  // (the read-before-write the spine's FXCH/fstore_val/fst() reads rely on).
  assign st0 = fpr[ftop + 3'd0];
  assign st1 = fpr[ftop + 3'd1];
  assign st2 = fpr[ftop + 3'd2];
  assign st3 = fpr[ftop + 3'd3];
  assign st4 = fpr[ftop + 3'd4];
  assign st5 = fpr[ftop + 3'd5];
  assign st6 = fpr[ftop + 3'd6];
  assign st7 = fpr[ftop + 3'd7];
  assign rd_phys_top = fpr[ftop];
  assign ftop_o  = ftop;
  assign fstat_o = fstat;
  assign fctrl_o = fctrl;
  assign fptag_o = fptag;
  assign fip_o = fip; assign fcs_o = fcs;
  assign fdp_o = fdp; assign fds_o = fds;
  assign fpr_flat_o = {fpr[7],fpr[6],fpr[5],fpr[4],fpr[3],fpr[2],fpr[1],fpr[0]};

  // ---- the synchronous state update. ALL write indices are computed from the
  // REGISTERED `ftop` here, and ftop is updated in this same block, so the
  // inline OLD-ftop NBA addressing (push uses ftop-1, pop uses ftop, sti uses
  // ftop+idx) is reproduced EXACTLY. The two writer arms are runtime-exclusive,
  // so at most one we_* per category fires; the decode mirrors the inline
  // per-arm parallelism/priority. Note the textual order matches the inline
  // sites: the value/tag writes use the pre-edge ftop, and the ftop bump is a
  // peer NBA in the same clock (no read-after-write hazard).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // x87 reset = FNINIT state (control 0x037f, status 0, TOP 0, all empty).
      ftop  <= 3'd0;
      fctrl <= 16'h037f;
      fstat <= 16'h0000;
      fptag <= 8'hFF;
      for (int fi = 0; fi < 8; fi++) fpr[fi] <= 80'd0;
      fip <= 32'd0; fcs <= 16'd0; fdp <= 32'd0; fds <= 16'd0;
    end else begin
      // FNINIT (full reset state) — takes priority, same shape as the rst arm
      // but does NOT clear fpr[] (matches the inline FX_FNINIT, which only resets
      // ftop/fctrl/fstat/fptag and leaves the stack data in place).
      if (we_fninit) begin
        ftop  <= 3'd0;
        fctrl <= 16'h037f;
        fstat <= 16'h0000;
        fptag <= 8'hFF;
        fip <= 32'd0; fcs <= 16'd0; fdp <= 32'd0; fds <= 16'd0;
      end

      // (1) PUSH — ftop--, fpr[ftop-1]<=push_data, fptag[ftop-1]<=0 (OLD ftop).
      if (we_push) begin
        ftop                 <= ftop - 3'd1;
        fptag[ftop - 3'd1]   <= 1'b0;
        fpr[ftop - 3'd1]     <= push_data;
      end

      // (2) ARITH/UNARY at TOP — fpr[ftop]<=top_data.
      if (we_top) fpr[ftop] <= top_data;

      // (3) WRITE ST(i) physical — fpr[ftop+idx]<=data; tag cleared only when
      // wsti_clr_tag (FST_STI yes, AR_STI_ST0 no — matches the inline arms).
      if (we_sti) begin
        fpr[ftop + wsti_idx] <= wsti_data;
        if (wsti_clr_tag) fptag[ftop + wsti_idx] <= 1'b0;
      end

      // (4) FXCH 2-slot swap — fpr[ftop]<=fxch_a, fpr[ftop+idx]<=fxch_b. The
      // spine presents both PRE-edge values (read off st0/st(i)).
      if (we_fxch) begin
        fpr[ftop]            <= fxch_a;
        fpr[ftop + fxch_idx] <= fxch_b;
      end

      // (5) POP — fptag[ftop]<=1, ftop<=ftop+1. Co-fires with we_sti/we_top/
      // we_fstat (the inline conditional-pop arms).
      if (we_pop) begin
        fptag[ftop] <= 1'b1;
        ftop        <= ftop + 3'd1;
      end

      // (6) POP2 (FCOMPP/FUCOMPP) — two adjacent tag bits + ftop+=2.
      if (we_pop2) begin
        fptag[ftop]        <= 1'b1;
        fptag[ftop + 3'd1] <= 1'b1;
        ftop               <= ftop + 3'd2;
      end

      // (7) FFREE — fptag[ftop+idx]<=1 (arbitrary index, no ftop change).
      if (we_ffree) fptag[ftop + ffree_idx] <= 1'b1;

      // (8) INCSTP / DECSTP — ftop +/- 1 (fstat clear rides we_fstat).
      if (we_incstp) ftop <= ftop + 3'd1;
      if (we_decstp) ftop <= ftop - 3'd1;

      // (9) DIRECT scalar writes — fctrl<=fctrl_wval (FLDCW); fstat replace.
      if (we_fctrl) fctrl <= fctrl_wval;
      if (we_fstat) fstat <= fstat_wval;

      // (10) M11 env-pointer latches. we_eptr fires on every non-control FP op
      // (FIP=instr addr, FCS=code sel); we_dptr only on memory-operand FP ops
      // (FDP=operand addr, FDS=data sel). Both are cleared by FNINIT above (admin
      // ops never assert we_eptr/we_dptr, so there is no same-clock conflict).
      if (we_eptr) begin fip <= eptr_fip; fcs <= eptr_fcs; end
      if (we_dptr) begin fdp <= dptr_fdp; fds <= dptr_fds; end

      // (11) M11b FLDENV/FRSTOR commit: CW/SW/TOP/tags loaded verbatim (no masking);
      // FRSTOR also reloads the 8 physical register values.
      if (we_envld) begin
        fctrl <= env_fctrl;
        ftop  <= env_ftop;
        fstat <= env_fstat;
        fptag <= env_fptag;
      end
      if (we_envregs)
        for (int fi = 0; fi < 8; fi++) fpr[fi] <= env_fpr_flat[fi*80 +: 80];

      // (12) +VEN_FP_PIPE deferred-arith commit (absolute phys index). Inert when
      // we_wabs/we_wabs_fstat are tied 0 (the default, non-pipelined build). A
      // pipelined arith op suppresses its same-cycle we_top/we_fstat, so there is
      // no double-write to fpr[wabs_idx] / fstat from one op.
      if (we_wabs)       fpr[wabs_idx] <= wabs_data;
      if (we_wabs_fstat) fstat         <= wabs_fstat;
    end
  end

endmodule : fpu_top
