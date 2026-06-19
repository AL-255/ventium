// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/fpu_writeback.sv — the x87 FP WRITE-DRIVER, extracted from core.sv
//                         (R3 modularization; behaviour-preserving).
//
// This is the single big combinational `always_comb` block that re-derives every
// x87 architectural-state MUTATION (the FAST cycle-mode commit arm + the SLOW
// S_FEXEC / S_FSTORE arms + the iterative-engine done-clock commits) and drives
// the fpu_top (u_fpu_state) write ports (fp_we_* / fp_*_data / ...). It was
// lifted VERBATIM out of core.sv into this true module; core.sv keeps the fp_we_*
// /fp_*_data wires (they connect this instance to the fpu_top instance) and the
// FSM/pipeline spine.
//
// PURE REFACTOR: the moved logic is byte-for-byte the original. Every signal the
// block ASSIGNS that is read by the fpu_top instance (or the iterative engines)
// is exposed as a same-named module OUTPUT port; every architectural/decoded/
// fpu-readback/engine-result signal the block READS is a same-named INPUT port.
// The block-local `automatic` scratch vars stay inside the always_comb. The
// pre-existing inferred latches (s_cmp_*, fstore_last_beat — block locals) and
// the fp_* commit defaults are preserved exactly (no added else arms).
//
// Type-visibility: the block does `case(state)` over the FSM enum `state_e`,
// whose S_* labels were an in-`core` typedef. That typedef is PROMOTED to
// compilation-unit ($unit) scope at the TOP of core.sv (next to sysop_e, the R3
// precedent); core.sv precedes this file in rtl/ventium.f, so this module's
// `input state_e state` port resolves to the same one $unit type. fxop_e/FX_*,
// FK_*, fpd_t and fx_pipe_t come from the imported packages (unchanged).
//
// The `fst(i)` ST-read helper (= fp_st[i]) is module-local in core.sv (it reads
// module state); it is copied here verbatim — fp_st[] and ftop are inputs.

module fpu_writeback
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
#(
    parameter logic [15:0] SEG_CS = 16'h0023,
    parameter logic [15:0] SEG_DS = 16'h002b
) (
    // ===== INPUTS ==========================================================
    // FSM state + config
    input  state_e      state,
    input  logic [4:0]  errata_en,

    // decoded fast-path instruction structs (fpd_t)
    input  fpd_t        u_d,
    input  fpd_t        v_d,

    // slow-path x87 decode latch fields
    input  fxop_e       q_fxop,
    input  logic        q_f_mem_read,
    input  logic        q_f_mem_write,
    input  logic [3:0]  q_f_mbytes,
    input  logic        q_f_pop,
    input  logic [2:0]  q_f_sti,
    input  logic [2:0]  q_f_aluop,
    input  logic [2:0]  q_f_const,
    input  logic [31:0] q_pc,
    input  logic [31:0] q_ea,
    input  logic [31:0] dbase,

    // memory / operand
    input  logic        mem_ack,
    input  logic [31:0] mem_rdata,
    input  logic [79:0] f_mem80,
    input  logic [3:0]  f_step,
    input  logic [4:0]  f_seq_step,
    input  logic [31:0] env_tmp [27],

    // fpu_top architectural-state readback
    input  logic [79:0] fp_st [8],
    input  logic [2:0]  ftop,
    input  logic [15:0] fctrl,
    input  logic [15:0] fstat,
    input  logic [7:0]  fptag,

    // pipeline / cycle gating
    input  logic        xlate_miss,
    input  logic [6:0]  stall_cnt,
    input  logic        pipe_bytes_ok,
    input  logic [6:0]  pending_mem_pen,
    input  logic        v_bytes_ok,
    input  logic [31:0] core_cyc,
    input  logic [31:0] fp_ready_cyc,
    input  logic        fp_occ_pending,

    // FP-store sticky-exception inputs
    input  logic        fstore_ie,
    input  logic        fstore_pe,
    input  logic        fstore_oe,    // FST m32/m64 narrowing overflow (OE)
    input  logic        fstore_ue,    // FST m32/m64 narrowing underflow (UE)
`ifdef VEN_FP_OVERLAP
    input  logic [31:0] fp_busy_cyc,
`endif

    // iterative-engine done / result inputs (the engine result-bus the slow-arm
    // done-clock commits read; declared unconditionally, read under matching
    // `ifdef` arms inside the block).
    input  logic        eng_div_done,
    input  logic [80:0] eng_div_result,
    input  logic        eng_sqrt_done,
    input  logic [80:0] eng_sqrt_result,
    input  logic        eng_bcd_done,
    input  logic [81:0] eng_bcd_result,
    input  logic        eng_fbld_done,
    input  logic [79:0] eng_fbld_result,
    input  logic        eng_trsc_done,
    input  logic [79:0] eng_trsc_result,
    input  logic        eng_trsc_pe,
    input  logic        eng_trsc_ie,
    input  logic        eng_trsc_c2,
`ifdef VEN_TRANSCENDENTAL
    input  logic [79:0] eng_fs_sin,
    input  logic [79:0] eng_fs_cos,
`endif
    input  logic        eng_fprem_done,
    input  logic        eng_fprem_c2,
    input  logic        eng_fprem_ie,
    input  logic [79:0] eng_fprem_result,
    input  logic [2:0]  eng_fprem_q012,

`ifdef VEN_FP_PIPE
    // +VEN_FP_PIPE 1-deep FP-execute pipeline registers (read here, written by the
    // always_ff in core.sv).
    input  logic        fpp_valid,
    input  logic [2:0]  fpp_aluop,
    input  logic [79:0] fpp_a,
    input  logic [79:0] fpp_b,
    input  logic [1:0]  fpp_rc,
    input  logic        fpp_err,
    input  logic [2:0]  fpp_dst,
`ifdef VEN_FP_PIPE2
    input  logic        fpp2_valid,
    input  fx_pipe_t    fpp2_s1,
    input  logic [1:0]  fpp2_rc,
    input  logic [2:0]  fpp2_dst,
`endif
`endif

`ifdef VEN_FPTRAP
    input  logic        fptrap_resp_valid,
    input  logic [79:0] fptrap_result,
`endif

    // ===== OUTPUTS (drive the fpu_top write ports + the iterative engines) ==
    output logic        fp_we_push,
    output logic [79:0] fp_push_data,
    output logic        fp_we_top,
    output logic [79:0] fp_top_data,
    output logic        fp_we_fstat,
    output logic [15:0] fp_fstat_wval,
    output logic        fp_we_sti,
    output logic [2:0]  fp_wsti_idx,
    output logic [79:0] fp_wsti_data,
    output logic        fp_wsti_clr_tag,
    output logic        fp_we_fxch,
    output logic [2:0]  fp_fxch_idx,
    output logic [79:0] fp_fxch_a,
    output logic [79:0] fp_fxch_b,
    output logic        fp_we_pop,
    output logic        fp_we_pop2,
    output logic        fp_we_ffree,
    output logic [2:0]  fp_ffree_idx,
    output logic        fp_we_incstp,
    output logic        fp_we_decstp,
    output logic        fp_we_fctrl,
    output logic [15:0] fp_fctrl_wval,
    output logic        fp_we_fninit,
    // iterative SRT FDIV/FSQRT engine handshake + inputs
    output logic        fp_div_elig,
    output logic        fp_sqrt_elig,
    output logic        fp_iter_go,
    output logic        fp_iter_done,
    output logic [79:0] eng_div_a,
    output logic [79:0] eng_div_b,
    output logic [79:0] eng_sqrt_in,
    output logic [1:0]  eng_rc,
    output logic        eng_div_start,
    output logic        eng_sqrt_start,
    // M11 env-pointer latch driver
    output logic        fp_we_eptr,
    output logic [31:0] fp_eptr_fip,
    output logic [15:0] fp_eptr_fcs,
    output logic        fp_we_dptr,
    output logic [31:0] fp_eptr_fdp,
    output logic [15:0] fp_eptr_fds,
    // M11b FLDENV/FRSTOR commit driver
    output logic        fp_we_envld,
    output logic [15:0] fp_env_fctrl,
    output logic [2:0]  fp_env_ftop,
    output logic [15:0] fp_env_fstat,
    output logic [7:0]  fp_env_fptag,
    output logic        fp_we_envregs,
    output logic [639:0] fp_env_fpr_flat,
    // +VEN_FP_PIPE deferred-arith commit port drivers (tied 0 unless piped)
    output logic        fp_we_wabs,
    output logic        fp_we_wabs_fstat,
    output logic [2:0]  fp_wabs_idx,
    output logic [79:0] fp_wabs_data,
    output logic [15:0] fp_wabs_fstat
`ifdef VEN_FP_PIPE
    ,
    // +VEN_FP_PIPE combinational capture lines (latched into fpp_* by core.sv's
    // always_ff) + the RAW-hazard stall flag.
    output logic        fp_pipe_cap,
    output logic [2:0]  fp_cap_aluop,
    output logic [2:0]  fp_cap_dst,
    output logic [79:0] fp_cap_a,
    output logic [79:0] fp_cap_b,
    output logic [1:0]  fp_cap_rc,
    output logic        fp_cap_err,
    output logic        fp_pipe_rd_haz
`ifdef VEN_FP_PIPE2
    ,
    output fx_pipe_t    fp_s1_next
`endif
`endif
);

  // errata_en bit index used by the FDIV/SRT-divide arms — same constant value as
  // core.sv's `localparam int ERR_FDIV = 0` (Erratum 23). The block reads only this
  // one errata index, so just the constant is replicated here (behaviour-identical).
  localparam int ERR_FDIV = 0;

  // st(i) read helper — copied VERBATIM from core.sv (module-local there because
  // it reads module state). fst(i) = fp_st[i] (= fpr[ftop+i], TOP-relative).
  function automatic logic [79:0] fst(input logic [2:0] i); return fp_st[i]; endfunction

  always_comb begin
    // ---- per-arm locals -------------------------------------------------------
    logic        fp_in_pipe, fp_halt4, fp_fp_arm, fp_fast_commit;
    logic        f_is_admin;
    logic [639:0] frstor_streg;   // M11b FRSTOR: loaded ST region (logical ST0..7)
    int          frli;            // M11b FRSTOR: logical index for a physical reg
    logic [31:0] fp_dep_ready;
    logic [84:0] fp_arf;          // {ie, ze, oe, ue, pe, result} from f_eval (fast)
    logic        slow_arm;        // S_FEXEC, op actually executes (not f_pc_bad)
    logic        slow_pc_bad, slow_is_arith;
    logic [79:0] s_opnd_f, s_argb, s_st0v, s_stiv;
    logic [79:0] s_fa, s_fb;      // shared arith operands (mux-then-eval, R-area)
    logic [84:0] s_arf;
    logic [80:0] s_ar;
    logic [2:0]  s_codes;
    logic [3:0]  s_xc;
    logic        s_cmp_ie;
    logic [79:0] s_cmp_b;            // shared FP-compare operand (mux-then-eval)
    logic        s_cmp_sig;          // signaling vs quiet for fcom_ie
    logic [15:0] s_cmp_fstat;        // shared apply_cmp result
    logic [1:0]  s_rc;
    logic        fstore_last_beat;
    // D9 extended-op temps (FRNDINT / FSCALE / FPREM)
    logic [65:0] s_ri;                       // fx_to_int_ex result {ovf,inexact,sval}
    logic signed [63:0] s_qn;                // FSCALE: trunc(ST1); FPREM: quotient
    logic signed [17:0] s_se;                // FSCALE: ST0 biased-exp + n
    logic [79:0] s_st1v;                     // ST1
    logic [80:0] s_pr;                       // FPREM: ST0 - Q*ST1

    // default: no writes this clock
    fp_we_push=1'b0; fp_push_data=80'd0;
    fp_we_top=1'b0;  fp_top_data=80'd0;
    fp_we_fstat=1'b0; fp_fstat_wval=16'd0;
    fp_we_sti=1'b0;  fp_wsti_idx=3'd0; fp_wsti_data=80'd0; fp_wsti_clr_tag=1'b0;
    fp_we_fxch=1'b0; fp_fxch_idx=3'd0; fp_fxch_a=80'd0; fp_fxch_b=80'd0;
    fp_we_pop=1'b0;  fp_we_pop2=1'b0;
    fp_we_ffree=1'b0; fp_ffree_idx=3'd0;
    fp_we_incstp=1'b0; fp_we_decstp=1'b0;
    fp_we_fctrl=1'b0; fp_fctrl_wval=16'd0;
    fp_we_fninit=1'b0;
    // iterative SRT engine defaults (0 => combinational path, default build)
    fp_div_elig=1'b0; fp_sqrt_elig=1'b0; fp_iter_go=1'b0; fp_iter_done=1'b0;
    eng_div_a=80'd0; eng_div_b=80'd0; eng_sqrt_in=80'd0; eng_rc=2'd0;
    eng_div_start=1'b0; eng_sqrt_start=1'b0;
    fp_we_eptr=1'b0; fp_eptr_fip=32'd0; fp_eptr_fcs=16'd0;
    fp_we_dptr=1'b0; fp_eptr_fdp=32'd0; fp_eptr_fds=16'd0;
    fp_we_envld=1'b0; fp_env_fctrl=16'd0; fp_env_ftop=3'd0; fp_env_fstat=16'd0; fp_env_fptag=8'd0;
    fp_we_envregs=1'b0; fp_env_fpr_flat=640'd0;
    fp_we_wabs=1'b0; fp_wabs_idx=3'd0; fp_wabs_data=80'd0;
    fp_we_wabs_fstat=1'b0; fp_wabs_fstat=16'd0;
`ifdef VEN_FP_PIPE
    fp_pipe_cap=1'b0; fp_cap_aluop=3'd0; fp_cap_dst=3'd0;
    fp_cap_a=80'd0; fp_cap_b=80'd0; fp_cap_rc=2'd0; fp_cap_err=1'b0;
    // Read-after-write hazard on the in-flight arith target: an FP op issuing the
    // SAME clock the deferred result is being written (we_wabs) would read the
    // PRE-edge stale fpr[fpp_dst]. Stall its issue 1 clock (the result lands this
    // edge, fresh next clock). Role>=2 consumers are already scoreboard-stalled
    // past this window, so this only bites role-0/1 readers (FXCH/FLDSTI/slow FST/
    // FCOM) — none of which appear in the throughput microbench, so the FP cycle
    // bands are preserved. Checks both ST0 (ftop) and ST(i) against the target.
`ifdef VEN_FP_PIPE2
    // ===== 2-STAGE split commit (see the fpp2_* declarations) ================
    // Stage 1 (combinational; registered into fpp2_s1 at this edge): the f_eval_s1
    // FRONT of the captured op. Only sampled when fpp_valid, so the unconditional
    // assign is safe and latch-free. VEN_FP_PIPE2 REQUIRES VEN_SRT_ITER (the engine
    // owns divide, so the split eval's div default is unreachable — same guard the
    // 1-stage split relies on).
    fp_s1_next = f_eval_s1(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err);
    // The in-flight result is now 2 clocks deep, so the RAW hazard spans BOTH slots:
    // stall a role-0/1 reader of the stage-0 target (fpp_dst, commits in 2 clocks)
    // OR the stage-1 target (fpp2_dst, commits THIS edge — the same pre-edge stale
    // read the 1-stage guarded). Role>=2 consumers are scoreboard-stalled to issue+3
    // (= this commit clock), so the throughput kernels never hit it and the FP bands
    // are preserved; it only bites FXCH/FLDSTI/slow FST/FCOM, as before.
    fp_pipe_rd_haz = u_d.is_fp &&
        ( (fpp_valid  && ((ftop==fpp_dst)  || (((ftop + u_d.fp_sti) & 3'd7)==fpp_dst)))
        ||(fpp2_valid && ((ftop==fpp2_dst) || (((ftop + u_d.fp_sti) & 3'd7)==fpp2_dst))) );
    // Stage 2 (cycle N+2): finish f_eval_s2 from the REGISTERED stage-1 result and
    // commit to the absolute target. This is the SHORT back-half cone (round_pack
    // only); the front half was spent the previous clock — that is the whole split.
    if (fpp2_valid) begin
      automatic logic [84:0] pp_arf = f_eval_s2(fpp2_s1, fpp2_rc);
      fp_we_wabs       = 1'b1;
      fp_wabs_idx      = fpp2_dst;
      fp_wabs_data     = pp_arf[79:0];
      fp_we_wabs_fstat = 1'b1;
      fp_wabs_fstat    = f_arith_fstat(fstat, pp_arf);
    end
`else
    fp_pipe_rd_haz = fpp_valid && u_d.is_fp &&
                     ((ftop==fpp_dst) || (((ftop + u_d.fp_sti) & 3'd7)==fpp_dst));
    // Deferred FK_ARITH commit (cycle N+1): the captured op's f_eval is computed
    // HERE (from the registered fpp_* operands — the short, post-register path)
    // and written to the absolute target via we_wabs. f_arith_fstat merges into
    // the CURRENT fstat (sticky-OR; nothing else writes fstat this clock because a
    // consumer that would is scoreboard-stalled past the in-flight window).
    if (fpp_valid) begin
`ifdef VEN_SRT_ITER
      // P0-13 FP area: use the SPLIT eval (f_eval_s1 front -> f_eval_s2 round).
      // The full f_eval builds fx_add's AND fx_mul's fx_round_pack cones (two
      // 128-bit normalize/round trees); the split muxes the two FRONTS and runs
      // ONE shared round_pack -> drops a whole round cone. BIT-EXACT for add/sub/
      // mul (verif/fppipe gate, 1M vectors). SAFE ONLY under +VEN_SRT_ITER: there
      // the iterative engine OWNS divide (normal divides are engine-routed; div is
      // never deferred to this commit port), so f_eval_s1's div-returns-0 default
      // is unreachable. Without VEN_SRT_ITER, divide DOES defer here -> keep the
      // full f_eval (below). Combinational s1->s2, same 1-clock defer as before.
      automatic logic [84:0] pp_arf = f_eval_s2(f_eval_s1(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err), fpp_rc);
`else
      automatic logic [84:0] pp_arf = f_eval(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err);
`endif
      fp_we_wabs       = 1'b1;
      fp_wabs_idx      = fpp_dst;
      fp_wabs_data     = pp_arf[79:0];
      fp_we_wabs_fstat = 1'b1;
      fp_wabs_fstat    = f_arith_fstat(fstat, pp_arf);
    end
`endif
`endif

    // ===== FAST ARM (M5 cycle-mode FP issue+commit) — same guard as ic_fp_commit.
    fp_in_pipe = (state==S_PIPE) && !xlate_miss && (stall_cnt==7'd0) &&
                 pipe_bytes_ok && (pending_mem_pen==7'd0);
    fp_halt4   = u_d.is_fp && (u_d.fp_kind==FK_ARITH) && (fctrl[9:8]!=2'b11);
    fp_fp_arm  = fp_in_pipe && !fp_halt4 && u_d.is_fp;
    fp_dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
`ifdef VEN_FP_OVERLAP
    // GAP1 mirror (matches core_fastpath.svh + ic_dep_ready): following FP op waits
    // on the x87 exec unit (fp_busy_cyc); FXCH (a rename) is exempt.
    if (u_d.fp_kind != FK_FXCH
        && $signed(fp_busy_cyc - core_cyc) > 0
        && $signed(fp_busy_cyc - fp_dep_ready) > 0)
      fp_dep_ready = fp_busy_cyc;
`endif
    fp_fast_commit = fp_fp_arm &&
                     !(!fp_occ_pending && ($signed(fp_dep_ready - core_cyc) > 0)) &&
                     !(!fp_occ_pending && (u_d.fp_occ > 7'd1));
`ifdef VEN_FP_PIPE
    // Fast-arm arith is DEFERRED: the live-operand f_eval is removed from the
    // issue cone (that is the whole point — the eip->icache->decode->f_eval->fpr
    // path is what we are splitting). The result is computed one clock later from
    // the REGISTERED fpp_* operands in the we_wabs deferred-commit block above.
    fp_arf = 83'd0;
`else
    fp_arf = f_eval(u_d.fp_aluop, fst(3'd0), fst(u_d.fp_sti), fctrl[11:10], errata_en[ERR_FDIV]);
`endif
    if (fp_fast_commit) begin
      unique case (u_d.fp_kind)
        FK_FLDC:   begin
`ifdef VEN_FXCH_FREE
          // GAP2 fold: fld-const + a following free FXCH %st(i) in ONE write — the
          // pushed const lands in st(i), the old st(i-1) becomes the new st0 (pre-edge
          // ftop addressing: we_push->fpr[ftop-1], we_sti(i-1)->fpr[ftop+i-1]).
          if (v_d.is_fxch_free && v_bytes_ok && v_d.fp_sti!=3'd0) begin
            fp_we_push=1'b1; fp_push_data=fst(v_d.fp_sti - 3'd1);
            fp_we_sti=1'b1;  fp_wsti_idx=v_d.fp_sti - 3'd1;
            fp_wsti_data=fconst(u_d.fp_sti); fp_wsti_clr_tag=1'b1;
          end else
`endif
          begin fp_we_push=1'b1; fp_push_data=fconst(u_d.fp_sti); end
        end
        FK_FLDSTI: begin
`ifdef VEN_FXCH_FREE
          if (v_d.is_fxch_free && v_bytes_ok && v_d.fp_sti!=3'd0) begin
            fp_we_push=1'b1; fp_push_data=fst(v_d.fp_sti - 3'd1);
            fp_we_sti=1'b1;  fp_wsti_idx=v_d.fp_sti - 3'd1;
            fp_wsti_data=fst(u_d.fp_sti); fp_wsti_clr_tag=1'b1;
          end else
`endif
          begin fp_we_push=1'b1; fp_push_data=fst(u_d.fp_sti); end
        end
        FK_ARITH:  begin
`ifdef VEN_FP_PIPE
          // DEFERRED: capture operands (signalled to the always_ff) and commit one
          // clock later via we_wabs — the same-cycle fpr/fstat write is suppressed
          // so the eip->...->f_eval->fpr cone is split across two clocks.
          fp_pipe_cap  = 1'b1;
          fp_cap_aluop = u_d.fp_aluop;
          fp_cap_a     = fst(3'd0);
          fp_cap_b     = fst(u_d.fp_sti);
          fp_cap_rc    = fctrl[11:10];
          fp_cap_err   = errata_en[ERR_FDIV];
          fp_cap_dst   = ftop;            // ST0 absolute physical index
`else
          fp_we_top=1'b1;   fp_top_data=fp_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, fp_arf);
`endif
        end
        FK_FSTP0:  begin fp_we_pop=1'b1; end
        FK_FXCH:   begin
          fp_we_fxch=1'b1; fp_fxch_idx=u_d.fp_sti;
          fp_fxch_a=fst(u_d.fp_sti);   // -> fpr[ftop]
          fp_fxch_b=fst(3'd0);         // -> fpr[ftop+idx]
        end
        default: ;
      endcase
    end

    // ===== SLOW ARM (S_FEXEC) — recompute exactly what the inline case did.
    slow_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                    (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                    (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                    (q_fxop==FX_FSQRT);
`ifdef VEN_FP_PC_RELAX
    // Must track the core_fp_exec.svh gate exactly so the fp_we_* commit driver
    // and the FSM spine re-derive the SAME (state==S_FEXEC && !pc_bad) predicate.
    slow_pc_bad = 1'b0;
`else
    slow_pc_bad = slow_is_arith && (fctrl[9:8] != 2'b11);
`endif
    slow_arm    = (state==S_FEXEC) && !slow_pc_bad;

    // ===== M11 env-pointer latch (func path = the slow arm; one S_FEXEC commit
    // per FP op). FIP=instr addr (q_pc) + FCS latch on every NON-control FP op
    // (incl FNSTSW %ax); FDP=operand addr (dbase+q_ea) + FDS only on memory-
    // operand FP ops. Control/admin ops below do NOT update the pointers; FNINIT
    // CLEARS them (via fp_we_fninit -> u_fpu_state). (M11a: inert -- nothing reads
    // fip/fcs/fdp/fds until M11b decodes FNSTENV/FNSAVE.)
    f_is_admin = (q_fxop==FX_FNINIT) || (q_fxop==FX_FNCLEX) || (q_fxop==FX_FNSTCW) ||
                 (q_fxop==FX_FNSTSW_M) || (q_fxop==FX_FLDCW) || (q_fxop==FX_FWAIT) ||
                 (q_fxop==FX_FNSTENV) || (q_fxop==FX_FLDENV) ||
                 (q_fxop==FX_FNSAVE)  || (q_fxop==FX_FRSTOR);
    if (slow_arm && !f_is_admin) begin
      fp_we_eptr  = 1'b1; fp_eptr_fip = q_pc; fp_eptr_fcs = SEG_CS;
      if (q_f_mem_read || q_f_mem_write) begin
        fp_we_dptr = 1'b1; fp_eptr_fdp = dbase + q_ea; fp_eptr_fds = SEG_DS;
      end
    end

    // M11b FLDENV/FRSTOR commit on the LAST load beat: reload CW/SW/TOP verbatim +
    // re-derive the per-reg empty bits from the loaded FTW (env_tmp[] holds the read
    // dwords; 0=CW,1=SW,2=FTW). FRSTOR also reloads the 8 ST regs (see below).
    if (state==S_FENV_LD && mem_ack &&
        f_seq_step == ((q_fxop==FX_FRSTOR) ? 5'd26 : 5'd6)) begin
      fp_we_envld  = 1'b1;
      fp_env_fctrl = env_tmp[0][15:0];
      fp_env_ftop  = env_tmp[1][13:11];
      // qemu cpu_set_fpus: clear TOP (0x3800) AND the B bit (0x8000), then re-derive
      // B from SE (bit7) -- B is NOT loaded verbatim (FERR# busy mirrors SE).
      fp_env_fstat = (env_tmp[1][15:0] & ~16'h3800 & ~16'h8000)
                     | (env_tmp[1][7] ? 16'h8000 : 16'd0);
      for (int p = 0; p < 8; p++) fp_env_fptag[p] = (env_tmp[2][p*2 +: 2] == 2'b11);
      // FRSTOR also reloads the 8 ST registers. The ST region (image dwords 7..26)
      // is env_tmp[7..25] plus mem_rdata for dword 26 (latched THIS beat as an NBA,
      // so read it live, not from env_tmp). Logical slot i -> physical fpr[(ftop+i)],
      // i.e. fpr[p] = logical ST((p - loaded_ftop)&7).
      if (q_fxop==FX_FRSTOR) begin
        fp_we_envregs = 1'b1;
        for (int j = 0; j < 20; j++)
          frstor_streg[j*32 +: 32] = (j==19) ? mem_rdata : env_tmp[7+j];
        for (int p = 0; p < 8; p++) begin
          frli = (p - int'(env_tmp[1][13:11])) & 7;
          fp_env_fpr_flat[p*80 +: 80] = frstor_streg[frli*80 +: 80];
        end
      end
    end

    // M11b FNSAVE reinitializes the FPU (= FNINIT) AFTER the last store beat. The
    // store data on that beat is combinational from the CURRENT (pre-reinit) state,
    // and fp_we_fninit is an NBA applied at the same edge -> the image captures the
    // pre-reinit state and the live state reinitializes. (FNSTENV has no side effect.)
    if (state==S_FENV_ST && mem_ack && q_fxop==FX_FNSAVE && f_seq_step==5'd26)
      fp_we_fninit = 1'b1;
    s_opnd_f = q_f_mem_read ? f_mem_as_float(f_mem80, q_f_mbytes) : 80'd0;
    s_st0v   = fst(3'd0);
    s_stiv   = fst(q_f_sti);
    s_st1v   = fst(3'd1);
    s_rc     = fctrl[11:10];
    s_ri = 66'd0; s_qn = 64'sd0; s_se = 18'sd0; s_pr = 81'd0;
    s_argb   = 80'd0; s_codes = 3'd0; s_xc = 4'd0; s_cmp_ie = 1'b0;
    s_ar = 81'd0;
    // R-area: ONE shared arithmetic eval. The four S_FEXEC arith commit arms used
    // to each call f_eval with their own operands — synth built FOUR full add/mul/
    // round cones (~6K LUT each) then muxed the outputs. Mux the OPERANDS per
    // q_fxop here, then call f_eval ONCE (compute-then-mux -> mux-then-compute).
    // Behaviour-identical: each arm's (a,b) is reproduced exactly; s_arf is only
    // consumed by those arms (and harmlessly computed for non-arith ops). The
    // VEN_SRT_ITER divide-eligibility block below also reuses s_fa/s_fb.
    unique case (q_fxop)
      FX_AR_STI_ST0:        begin s_fa = s_stiv; s_fb = s_st0v; end
      FX_AR_M32, FX_AR_M64: begin s_fa = s_st0v; s_fb = s_opnd_f; end
      FX_AR_I16, FX_AR_I32: begin s_fa = s_st0v; s_fb = f_mem_as_int(f_mem80, q_f_mbytes); end
      default:              begin s_fa = s_st0v; s_fb = s_stiv; end  // FX_AR_ST0_STI + non-arith
    endcase
`ifdef VEN_FP_PIPE
    // Slow-arm arith is SPLIT: S_FEXEC captures s_fa/s_fb into fpp_*, then
    // S_FEXEC_EX computes f_eval (from the registered operands) and commits via
    // we_wabs IN THE SAME CLOCK AS THE RETIRE (so the per-retire arch check is
    // exact — unlike a retire-before-commit defer). The combinational s_arf cone
    // (f_mem80->f_eval->fpr, the worst path) is dropped here.
    s_arf = 83'd0;
`else
    s_arf = f_eval(q_f_aluop, s_fa, s_fb, s_rc, errata_en[ERR_FDIV]);
`endif
    // R-area: ONE shared FP compare. The six compare arms (FCOM/FUCOM/FCOMPP/
    // FUCOMPP/FTST/FICOM) each called fcom_codes+fcom_ie+apply_cmp with their own
    // operand — synth built SIX compare cones then muxed. Mux the operand+signaling
    // per q_fxop, compute ONCE; each arm just routes s_cmp_fstat to fp_fstat_wval.
    unique case (q_fxop)
      FX_FCOM_STI:               begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b1; end
      FX_FCOM_M32, FX_FCOM_M64:  begin s_cmp_b = s_opnd_f;  s_cmp_sig = 1'b1; end
      FX_FUCOM_STI:              begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b0; end
      FX_FCOMPP:                 begin s_cmp_b = fst(3'd1); s_cmp_sig = 1'b1; end
      FX_FUCOMPP:                begin s_cmp_b = fst(3'd1); s_cmp_sig = 1'b0; end
      FX_FTST:                   begin s_cmp_b = 80'd0;     s_cmp_sig = 1'b1; end
      FX_FICOM_M16, FX_FICOM_M32:begin s_cmp_b = f_mem_as_int(f_mem80, q_f_mbytes); s_cmp_sig = 1'b1; end
      default:                   begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b1; end
    endcase
    s_codes     = fcom_codes(s_st0v, s_cmp_b);
    s_cmp_ie    = fcom_ie(s_st0v, s_cmp_b, s_cmp_sig);
    s_cmp_fstat = apply_cmp(fstat, s_codes, s_cmp_ie);
`ifdef VEN_SRT_ITER
    // ----- iterative SRT FDIV/FSQRT eligibility + engine inputs -------------
    // Route NORMAL-operand divides and +normal sqrt through the multi-cycle
    // engine; everything else (zero/Inf/NaN/denormal, runtime FDIV-errata) stays
    // on the combinational path (its flag/special logic below is preserved).
    begin
      logic na, nb;
      // operands are the shared s_fa/s_fb (the per-q_fxop mux computed above).
      // FINITE-NONZERO operands: exactly the set that reaches fx_srt_div's /
      // fx_isqrt's loop in f_eval's else (zero/Inf/NaN hit cheap guards). Routing
      // ALL of these to the engine lets the combinational loops be stubbed out of
      // synthesis (D8b); the engine == fx_srt_div / fx_sqrt for every operand.
      // NORMAL-only: the SRT/sqrt engines assume a normalized 1.f operand, so
      // denormal operands are EXCLUDED here and fall to the combinational path
      // (fx_div routes them to the denormal-aware fx_div_exact; fx_sqrt's eff-exp
      // path handles a denormal radicand). fx_is_normal == exp in (0,0x7fff) & v[63].
      na = fx_is_normal(s_fa);
      nb = fx_is_normal(s_fb);
      fp_div_elig = slow_arm && !errata_en[ERR_FDIV] &&
                    ((q_fxop==FX_AR_ST0_STI)||(q_fxop==FX_AR_STI_ST0)||
                     (q_fxop==FX_AR_M32)||(q_fxop==FX_AR_M64)||
                     (q_fxop==FX_AR_I16)||(q_fxop==FX_AR_I32)) &&
                    ((q_f_aluop==3'd6)||(q_f_aluop==3'd7)) && na && nb;
      fp_sqrt_elig = slow_arm && (q_fxop==FX_FSQRT) &&
                     fx_is_normal(s_st0v) && !s_st0v[79];
      fp_iter_go   = fp_div_elig || fp_sqrt_elig;
      // div: a/b as passed to fx_div (divr, aluop 7, swaps operands)
      eng_div_a    = (q_f_aluop==3'd7) ? s_fb : s_fa;
      eng_div_b    = (q_f_aluop==3'd7) ? s_fa : s_fb;
      eng_sqrt_in  = s_st0v;
      eng_rc       = s_rc;
      eng_div_start  = fp_div_elig;
      eng_sqrt_start = fp_sqrt_elig;
      fp_iter_done = (q_fxop==FX_FSQRT) ? eng_sqrt_done : eng_div_done;
    end
`endif
    if (slow_arm) begin
      unique case (q_fxop)
        // ---- loads (push) ----
        FX_FLD_M32, FX_FLD_M64, FX_FLD_M80: begin
          fp_we_push=1'b1; fp_push_data=(q_fxop==FX_FLD_M80) ? f_mem80 : s_opnd_f;
        end
        FX_FILD_M16, FX_FILD_M32, FX_FILD_M64: begin
          fp_we_push=1'b1; fp_push_data=f_mem_as_int(f_mem80, q_f_mbytes);
        end
        FX_FBLD: begin   // M10: packed-BCD m80 -> floatx80 (exact, <=18 digits)
`ifndef VEN_BCD_ITER
          fp_we_push=1'b1; fp_push_data=fx_bcd_to_fx(f_mem80);
`endif
          // under VEN_BCD_ITER: deferred to S_FBLD_BUSY (iterative ven_bcd_to_fp);
          // the push lands there with the engine result, same clock as the retire.
        end
        FX_FLDCONST: begin fp_we_push=1'b1; fp_push_data=fconst(q_f_const); end
        FX_FLD_STI:  begin fp_we_push=1'b1; fp_push_data=s_stiv;            end
        // ---- register moves / stack mgmt ----
        FX_FST_STI: begin
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_st0v; fp_wsti_clr_tag=1'b1;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FXCH: begin
          fp_we_fxch=1'b1; fp_fxch_idx=q_f_sti;
          fp_fxch_a=s_stiv;   // -> fpr[ftop]
          fp_fxch_b=s_st0v;   // -> fpr[ftop+idx]
        end
        FX_FFREE:   begin fp_we_ffree=1'b1; fp_ffree_idx=q_f_sti; end
        FX_FINCSTP: begin fp_we_incstp=1'b1; fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h4700; end
        FX_FDECSTP: begin fp_we_decstp=1'b1; fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h4700; end
        FX_FNOP:    begin /* no state change */ end
        FX_FWAIT:   begin /* no unmasked exception in corpus */ end
        FX_FNINIT:  begin fp_we_fninit=1'b1; end
        FX_FNCLEX:  begin fp_we_fstat=1'b1; fp_fstat_wval=fstat & 16'h7f00; end
        FX_FLDCW:   begin fp_we_fctrl=1'b1; fp_fctrl_wval=f_mem80[15:0]; end
        // ---- sign / abs on ST0 ----
        FX_FABS: begin fp_we_top=1'b1; fp_top_data={1'b0, s_st0v[78:0]}; end
        FX_FCHS: begin fp_we_top=1'b1; fp_top_data={~s_st0v[79], s_st0v[78:0]}; end
        // ---- compares ----
        // compares — s_cmp_fstat (== apply_cmp of the muxed s_cmp_b) is shared,
        // computed once above; each arm routes it + does its own pop/pop2.
        FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FUCOM_STI: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FCOMPP: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          fp_we_pop2=1'b1;
        end
        FX_FUCOMPP: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          fp_we_pop2=1'b1;
        end
        FX_FTST: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
        end
        FX_FXAM: begin
          s_xc = fxam_codes(s_st0v, fptag[ftop]);
          fp_we_fstat=1'b1;
          fp_fstat_wval = (fstat & ~16'h4700) |
                          ({1'd0,s_xc[3]}<<14) | ({5'd0,s_xc[2]}<<10) |
                          ({6'd0,s_xc[1]}<<9)  | ({7'd0,s_xc[0]}<<8);
        end
        FX_FICOM_M16, FX_FICOM_M32: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        // ---- arithmetic (f_eval -> {ie,ze,inexact,result}) ----
        // arith commit arms — s_arf (== f_eval of the muxed s_fa/s_fb) is shared,
        // computed once above; each arm just routes it to the right write port.
        // +VEN_FP_PIPE: capture s_fa/s_fb + the absolute dest into fpp_*; S_FEXEC
        // routes to S_FEXEC_EX where we_wabs commits (from the registered operands)
        // in the SAME clock as the retire. The pop for STI_ST0 stays here (cheap).
        FX_AR_ST0_STI: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_AR_STI_ST0: if (!fp_div_elig) begin
          // ST(i) op= ST0 : a=ST(i), b=ST0 (no tag write — only fpr[fri]).
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV];
          fp_cap_dst=(ftop + q_f_sti) & 3'd7;
          if (q_f_pop) fp_we_pop=1'b1;
`else
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_arf[79:0]; fp_wsti_clr_tag=1'b0;
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
          if (q_f_pop) fp_we_pop=1'b1;
`endif
        end
        FX_AR_M32, FX_AR_M64: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_AR_I16, FX_AR_I32: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_FSQRT: begin
          // QEMU helper_fsqrt. M12: intercept NaN FIRST (the bare fx_sqrt would do
          // mantissa math on a NaN and return garbage); sqrt(+Inf) is handled by
          // fx_sqrt's own +Inf guard. Everything else preserves the prior, gate-
          // proven sign-bit / C2 logic verbatim.
          if (fx_is_snan(s_st0v)) begin                       // SNaN -> QNaN, IE
            fp_we_top=1'b1;   fp_top_data=fx_quietize(s_st0v);
            fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001;
          end else if (fx_is_nan(s_st0v)) begin               // QNaN -> propagate, no flag
            fp_we_top=1'b1;   fp_top_data=s_st0v;
          end else if (s_st0v[79]) begin
            if (fx_is_neg(s_st0v)) begin                      // sqrt(neg non-zero) incl -Inf
              fp_we_top=1'b1;   fp_top_data=80'hFFFFC000000000000000;
              fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h4700) | 16'h0400 | 16'h0001; // C2+IE
            end else begin                                    // -0
              s_ar = fx_sqrt(s_st0v, s_rc);
              fp_we_top=1'b1;   fp_top_data=s_ar[79:0];
              fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h4700) | 16'h0400;            // C2 only
            end
          end else if (!fp_sqrt_elig) begin                   // +0, +Inf (+normal -> engine)
            s_ar = fx_sqrt(s_st0v, s_rc);
            fp_we_top=1'b1; fp_top_data=s_ar[79:0];
            if (s_ar[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end    // PE
          end
        end
        // ---- D9 FC FRNDINT: round ST0 to an integer-valued floatx80 per RC.
        // Inf/NaN/zero and already-integral magnitudes (uexp>=63: no fraction
        // bits) pass through unchanged; the finite fractional case round-trips
        // through the shared int converter (its exact inverse) and sets PE on a
        // changed value, preserving the sign of a result that rounds to zero.
        // (QEMU helper_frndint / floatx80_round_to_int.)
        FX_FRNDINT: begin
          if (fx_is_inf_nan(s_st0v) || fx_is_zero(s_st0v) || (fx_uexp(s_st0v) >= 32'sd63)) begin
            fp_we_top=1'b1; fp_top_data=s_st0v;
          end else begin
            s_ri = fx_to_int_ex(s_st0v, 64, s_rc);
            fp_we_top=1'b1;
            fp_top_data = (s_ri[63:0]==64'd0) ? fx_make(fx_sign(s_st0v), 15'd0, 64'd0)
                                              : fx_from_int($signed(s_ri[63:0]));
            if (s_ri[64]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end  // PE
          end
        end
        // ---- D9 FD FSCALE: ST0 = ST0 * 2^trunc(ST1) — add trunc(ST1) to ST0's
        // biased exponent. Inf/NaN/zero ST0 pass through; over/underflow saturate
        // to signed Inf/0 with OE/UE. (QEMU helper_fscale / floatx80_scalbn; the
        // power-of-two scale is exact, so the mantissa is preserved verbatim.)
        FX_FSCALE: begin
          if (fx_is_inf_nan(s_st0v) || fx_is_zero(s_st0v)) begin
            fp_we_top=1'b1; fp_top_data=s_st0v;
          end else begin
            s_ri = fx_to_int_ex(s_st1v, 64, 2'd3);            // trunc ST1 toward zero
            s_qn = $signed(s_ri[63:0]);
            if (s_qn >= 64'sd32768) begin                     // huge up-scale -> Inf (OE)
              fp_we_top=1'b1; fp_top_data=fx_make(fx_sign(s_st0v), 15'h7FFF, 64'h8000000000000000);
              fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0008;
            end else if (s_qn <= -64'sd32768) begin           // huge down-scale -> 0 (UE)
              fp_we_top=1'b1; fp_top_data=fx_make(fx_sign(s_st0v), 15'd0, 64'd0);
              fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0010;
            end else begin
              s_se = $signed({3'd0, fx_exp(s_st0v)}) + $signed(s_qn[17:0]);
              if (s_se >= 18'sd32767) begin                   // exponent overflow -> Inf (OE)
                fp_we_top=1'b1; fp_top_data=fx_make(fx_sign(s_st0v), 15'h7FFF, 64'h8000000000000000);
                fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0008;
              end else if (s_se <= 18'sd0) begin              // exponent underflow -> signed 0 (UE)
                fp_we_top=1'b1; fp_top_data=fx_make(fx_sign(s_st0v), 15'd0, 64'd0);
                fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0010;
              end else begin
                fp_we_top=1'b1; fp_top_data=fx_make(fx_sign(s_st0v), s_se[14:0], fx_man(s_st0v));
              end
            end
          end
        end
        // ---- memory stores: sticky PE/IE latch at dispatch (the store value +
        // pop happen later in S_FSTORE). FST m80/FNSTCW/FNSTSW m16 stay exact.
        FX_FST_M32, FX_FST_M64, FX_FST_M80,
        FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
        FX_FBSTP,
        FX_FNSTCW, FX_FNSTSW_M: begin
`ifdef VEN_BCD_ITER
          // iterative FBSTP defers its IE/PE sticky to the S_BCD_BUSY done clock
          // (fstore_ie/pe come from the engine, not valid yet here at S_FEXEC).
          if (q_fxop != FX_FBSTP) begin
`endif
          // IE is mutually exclusive with the numeric flags (QEMU signals invalid
          // OR the rounding flags). FST m32/m64 narrowing overflow/underflow set
          // OE/UE alongside PE (the narrow round is always inexact in those cases).
          if (fstore_ie) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end       // IE
          else if (fstore_oe || fstore_ue || fstore_pe) begin
            fp_we_fstat=1'b1;
            fp_fstat_wval = fstat | (fstore_oe ? 16'h0008 : 16'h0000)   // OE
                                  | (fstore_ue ? 16'h0010 : 16'h0000)   // UE
                                  | (fstore_pe ? 16'h0020 : 16'h0000);  // PE
          end
`ifdef VEN_BCD_ITER
          end
`endif
        end
        // FX_FNSTSW_AX writes gpr[EAX] only (handled in the S_FEXEC spine arm).
        default: ;
      endcase
    end

`ifdef VEN_BCD_ITER
    // iterative FBSTP: drive the deferred IE/PE fstat sticky on the engine-done
    // clock (the store value/flags only become known when the BCD engine finishes).
    if (state==S_BCD_BUSY && eng_bcd_done) begin
      if (eng_bcd_result[81])      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end // IE
      else if (eng_bcd_result[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end // PE
    end
    // iterative FBLD: push the converted floatx80 on the engine-done clock (the
    // same clock S_FBLD_BUSY retires -> the per-retire arch state is exact).
    if (state==S_FBLD_BUSY && eng_fbld_done) begin
      fp_we_push=1'b1; fp_push_data=eng_fbld_result;
    end
`endif

`ifdef VEN_SRT_ITER
    // ===== iterative engine result commit (S_FP_BUSY, when the engine is done).
    // Re-derives the dest write-port from q_fxop (which persists across the wait)
    // and uses the engine's registered {inexact,result}. normal/normal divide and
    // +normal sqrt only (so ie=ze=0; sqrt sets PE on inexact, like the comb arm).
    if (state==S_FP_BUSY && fp_iter_done) begin
      if (q_fxop==FX_FSQRT) begin
        fp_we_top=1'b1; fp_top_data=eng_sqrt_result[79:0];
        if (eng_sqrt_result[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end else begin
        logic [84:0] earf;
        earf = {4'b0000, eng_div_result[80], eng_div_result[79:0]};   // {ie,ze,oe,ue=0, pe, result}
        if (q_fxop==FX_AR_STI_ST0) begin
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=eng_div_result[79:0]; fp_wsti_clr_tag=1'b0;
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, earf);
          if (q_f_pop) fp_we_pop=1'b1;
        end else begin
          fp_we_top=1'b1; fp_top_data=eng_div_result[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, earf);
        end
      end
    end
`endif

`ifdef VEN_TRANSCENDENTAL
    // iterative transcendentals (#11): commit + fstat on the engine-done clock
    // (the same clock S_TRSC_BUSY retires -> per-retire arch state exact). IE has
    // priority over PE (mirrors FBSTP); the engine asserts PE for inexact results.
    // F2XM1 overwrites ST0 in place; FPATAN writes ST1 and POPS (result ends in
    // the new ST0), exactly like FDIVP ST1,ST0 (we_sti idx=1 + we_pop).
    if (state==S_TRSC_BUSY && eng_trsc_done) begin
      if (q_fxop==FX_FSIN || q_fxop==FX_FCOS) begin
        // FSIN/FCOS: in-place ST0. Out-of-range (|x|>=2^63) -> set C2, ST0
        // unchanged; else write result, clear C2, set PE (matches qemu's C2 flag
        // handling; the VALUE is the silicon model, more accurate than qemu's double).
        if (eng_trsc_c2) begin
          fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0400;     // C2 <- 1
        end else begin
          fp_we_top=1'b1; fp_top_data=eng_trsc_result;
          fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h0400) | 16'h0020;  // C2<-0, PE<-1
        end
      end else if (q_fxop==FX_FSINCOS || q_fxop==FX_FPTAN) begin
        // FSINCOS: ST0<-sin, push cos.  FPTAN: ST0<-tan(=sin/cos), push 1.0.
        // (we_top writes the OLD top = new ST1; we_push writes the new ST0.) C2
        // out-of-range -> no write, no push, ST0 unchanged.
        if (eng_trsc_c2) begin
          fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0400;
        end else begin
          // (part-select on a function call is illegal in synth/IEEE-1800 — temp it)
          logic [82:0] tan_q; tan_q = fx_div(eng_fs_sin, eng_fs_cos, 2'd0);
          fp_we_top=1'b1;
          fp_top_data=(q_fxop==FX_FPTAN) ? tan_q[79:0] : eng_fs_sin;
          fp_we_push=1'b1;
          fp_push_data=(q_fxop==FX_FPTAN) ? 80'h3fff8000000000000000 : eng_fs_cos;  // FPTAN pushes +1.0
          fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h0400) | 16'h0020;
        end
      end else if (q_fxop==FX_F2XM1) begin
        fp_we_top=1'b1; fp_top_data=eng_trsc_result;            // in-place ST0
        if (eng_trsc_ie)      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end
        else if (eng_trsc_pe) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end else begin
        // FPATAN / FYL2X / FYL2XP1: write ST1, then pop (result -> new ST0).
        fp_we_sti=1'b1; fp_wsti_idx=3'd1; fp_wsti_data=eng_trsc_result; fp_wsti_clr_tag=1'b0;
        fp_we_pop=1'b1;
        if (eng_trsc_ie)      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end
        else if (eng_trsc_pe) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end
    end
`endif

`ifdef VEN_FPREM
    // FPREM: write the remainder to ST0 in place + the condition codes on the engine
    // `done` clock (helper_fprem_common: clear C3/C2/C1/C0, then C0<-q2 C3<-q1 C1<-q0
    // on a completed reduction, or C2<-1 on a partial; IE on invalid operands).
    if (state==S_FPREM_BUSY && eng_fprem_done) begin
      logic [15:0] cc;
      fp_we_top=1'b1; fp_top_data=eng_fprem_result;          // remainder -> ST0
      cc = fstat & ~16'h4700;                                 // clear C3,C2,C1,C0
      if (eng_fprem_ie) cc = cc | 16'h0001;                   // IE
      else if (eng_fprem_c2) cc = cc | 16'h0400;              // C2 <- 1 (partial)
      else begin
        if (eng_fprem_q012[2]) cc = cc | 16'h0100;            // C0 <- q2
        if (eng_fprem_q012[1]) cc = cc | 16'h4000;            // C3 <- q1
        if (eng_fprem_q012[0]) cc = cc | 16'h0200;            // C1 <- q0
      end
      fp_we_fstat=1'b1; fp_fstat_wval=cc;
    end
`endif

`ifdef VEN_FPTRAP
    // FPATAN PS-trap: the PS computed atan2(ST1,ST0); commit it like FDIVP ST1,ST0 —
    // write ST1 then pop (result ends in the new ST0), same as the HW FPATAN commit.
    if (state==S_FPTRAP_WAIT && fptrap_resp_valid) begin
      fp_we_sti=1'b1; fp_wsti_idx=3'd1; fp_wsti_data=fptrap_result; fp_wsti_clr_tag=1'b0;
      fp_we_pop=1'b1;
    end
`endif

    // ===== SLOW ARM (S_FSTORE last beat) — the FSTP/FISTP pop.
    fstore_last_beat = (state==S_FSTORE) && mem_ack &&
                       ((q_f_mbytes<=4'd4) ||
                        (q_f_mbytes==4'd8 && f_step==4'd1) ||
                        (q_f_mbytes==4'd10 && f_step==4'd2));
    if (fstore_last_beat && q_f_pop) fp_we_pop=1'b1;
  end

endmodule
