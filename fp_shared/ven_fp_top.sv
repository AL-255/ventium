// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_top.sv -- instruction-level shell for the area-shared x87 FPU.
//
// This is intentionally one public hierarchy.  The CPU submits a decoded x87
// command and later receives a completion pulse.  Architectural state is owned
// here; execution children can therefore be replaced or retimed without
// spreading FP state mutations through the integer core.

`default_nettype none

module ven_fp_top
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst_n,

`ifdef VEN_SNAPSHOT_RESTORE
    // Reset-only simulation checkpoint input.  The full FPU environment is
    // carried so a post-init profile cannot hide a state-restore defect.
    input  wire logic         init_restore,
    input  wire logic [2:0]   init_top,
    input  wire logic [15:0]  init_status,
    input  wire logic [15:0]  init_control,
    input  wire logic [7:0]   init_tag,
    input  wire logic [31:0]  init_fip,
    input  wire logic [15:0]  init_fcs,
    input  wire logic [31:0]  init_fdp,
    input  wire logic [15:0]  init_fds,
    input  wire logic [639:0] init_regs_phys,
`endif

    input  wire logic         cmd_valid,
    output      logic         cmd_ready,
    // Asserted only for an accepted command whose architectural result is
    // completely committed on the acceptance edge and has no response payload
    // that the adapter must consume.  The producer may retire this command on that
    // edge; stores and FNSTSW AX must still await rsp_valid.
    output      logic         cmd_accept_retire,
    // One-cycle-ahead notification for a normal shared-ALU result.  It is
    // registered here, and means the state-file will commit that result on the
    // *current consumer edge*.  It is deliberately not a response/data path:
    // payload-producing, SRT, misc, BCD, and transcendental commands continue
    // to retire solely through rsp_valid.
    output      logic         alu_commit_retire,
    input  wire fxop_e        cmd_op,
    input  wire logic [2:0]   cmd_aluop,
    input  wire logic [2:0]   cmd_sti,
    input  wire logic         cmd_pop,
    input  wire logic [2:0]   cmd_constant,
    input  wire logic [79:0]  cmd_mem,
    input  wire logic [3:0]   cmd_mem_bytes,
    input  wire logic         cmd_fdiv_bug,
    input  wire logic         cmd_fist_bug,
    input  wire logic         cmd_env16,
    input  wire logic         cmd_real_mode,
    input  wire logic [863:0] cmd_env_image,
    input  wire logic         cmd_update_fip,
    input  wire logic [31:0]  cmd_fip,
    input  wire logic [15:0]  cmd_fcs,
    input  wire logic         cmd_update_fdp,
    input  wire logic [31:0]  cmd_fdp,
    input  wire logic [15:0]  cmd_fds,

    output      logic         busy,
    output      logic         rsp_valid,
    output      logic         rsp_unsupported,
    output      logic         rsp_stack_fault,
    output      logic [84:0]  rsp_arith,
    output      logic         rsp_store_valid,
    output      logic [863:0] rsp_store_data,
    output      logic [7:0]   rsp_store_bytes,
    output      logic         rsp_ax_valid,
    output      logic [15:0]  rsp_ax,

    // Architectural observation ports.  These also form the eventual
    // FNSTENV/FNSAVE integration boundary.
    output      logic [2:0]   ftop_o,
    output      logic [15:0]  fstat_o,
    output      logic [15:0]  fctrl_o,
    output      logic [7:0]   fptag_o,
    output      logic [31:0]  fip_o,
    output      logic [15:0]  fcs_o,
    output      logic [31:0]  fdp_o,
    output      logic [15:0]  fds_o,
    output      logic [639:0] fpr_phys_flat_o,
    output      logic [639:0] st_flat_o
);

  typedef enum logic [2:0] {
    TOP_IDLE, TOP_ALU, TOP_SRT, TOP_MISC, TOP_BCD_LOAD, TOP_BCD_STORE,
    TOP_TRANS, TOP_MEMDIV
  } top_state_t;
  top_state_t top_state;

  logic [79:0] st0_data, sti_data;
  logic st0_empty, sti_empty;
  logic [2:0] state_rd1_idx;

  // State commit wires.
  logic        c_init, c_push, c_write, c_swap, c_free;
  logic        c_swap_materialize_empty;
  logic        c_inc_top, c_dec_top, c_status, c_control;
  logic        c_eptr, c_dptr, c_env, c_env_regs;
  logic [79:0] c_push_data, c_write_data;
  logic [2:0]  c_write_idx, c_swap_idx, c_free_idx;
  logic        c_write_valid;
  logic [1:0]  c_pop;
  logic [15:0] c_status_data, c_control_data;
  logic [15:0] c_env_control, c_env_status;
  logic [2:0]  c_env_top;
  logic [7:0]  c_env_tag;
  logic [639:0] c_env_regs_phys;

  // Shared arithmetic pipeline.
  logic        alu_start, alu_busy, alu_done, alu_commit_next;
  logic [2:0]  alu_subop;
  logic [79:0] alu_a, alu_b;
  logic [84:0] alu_result;
  logic        alu_rounded_up;
  logic [2:0]  pending_dst;
  logic        pending_pop;
  fxop_e        pending_op;

  // One registered service for all rare narrow-store and conversion work.
  logic        misc_start, misc_busy, misc_done;
  logic [79:0] misc_value;
  logic        misc_ie, misc_oe, misc_ue, misc_pe, misc_rounded_up;
  logic        misc_tiny_nonzero, misc_fst_narrow, misc_fst_range_block;
  logic        misc_commit_ue, misc_commit_pe;
  logic        misc_frnd_denormal, misc_frnd_abort;
  // ST0 and CW cannot change while the serialized misc owner is pending.
  // No live command input participates in these exception/commit decisions.
  assign misc_frnd_denormal = (pending_op == FX_FRNDINT) &&
                             fx_is_denormal(st0_data) && !misc_ie;
  assign misc_frnd_abort = (pending_op == FX_FRNDINT) &&
      ((misc_ie && !fctrl_o[0]) || (misc_frnd_denormal && !fctrl_o[1]));
  // The pending owner and control word cannot change during TOP_MISC.
  // P54 memory range exceptions suppress both store and pop; precision
  // exceptions deliver the rounded value even with PM=0.
  assign misc_fst_narrow = pending_op inside {FX_FST_M32, FX_FST_M64};
  assign misc_commit_ue = misc_ue |
                          (misc_fst_narrow && misc_tiny_nonzero && !fctrl_o[4]);
  assign misc_fst_range_block = misc_fst_narrow &&
      ((misc_oe && !fctrl_o[3]) || (misc_tiny_nonzero && !fctrl_o[4]));
  assign misc_commit_pe = misc_pe && !misc_fst_range_block && !misc_frnd_abort;

  // Decimal conversion is iterative in both directions; no chained decimal
  // divide/multiply network is reachable from the command boundary.
  logic        bcd_load_start, bcd_load_busy, bcd_load_done;
  logic [79:0] bcd_load_result;
  logic        bcd_store_start, bcd_store_busy, bcd_store_done;
  logic [81:0] bcd_store_result;

  // One sequencer and one add/multiply pipeline for all transcendental ops.
  logic        trans_start, trans_busy, trans_done;
  logic [79:0] trans_primary, trans_secondary;
  logic        trans_c2, trans_ie, trans_pe;
  logic        trans_fx_req;
  logic [1:0]  trans_fx_op, trans_fx_rc, trans_fx_pc;
  logic [79:0] trans_fx_a, trans_fx_b;
  logic        trans_divide_start;
  logic [79:0] trans_divide_a, trans_divide_b;
  logic [1:0]  trans_divide_rc;

  // One iterative divider/square-root engine for the entire hierarchy.
  logic        srt_start, srt_busy, srt_done;
  logic        srt_bug_q;
  logic [1:0]  srt_mode;
  logic [1:0]  srt_rc, srt_pc;
  logic [79:0] srt_a, srt_b;
  logic [82:0] srt_result;
  logic        srt_rounded_up;
  logic [2:0]  srt_rem_q012;
  logic        srt_rem_c2, srt_rem_ie;
  logic        srt_rem_denormal, srt_rem_abort;
  // TOP_SRT serializes architectural stack/CW changes. Use fixed ST(1),
  // never sti_data: an unaccepted live command can change its read index.
  assign srt_rem_denormal =
      (pending_op inside {FX_FPREM, FX_FPREM1}) && !srt_rem_ie &&
      !fx_is_nan(st0_data) && !fx_is_nan(st_flat_o[159:80]) &&
      (fx_is_denormal(st0_data) || fx_is_denormal(st_flat_o[159:80]));
  assign srt_rem_abort = (srt_rem_ie && !fctrl_o[0]) ||
                         (srt_rem_denormal && !fctrl_o[1]);

  // Memory divide alone captures raw memory bits before format conversion.
  // Do not feed live cmd_mem through the SRT operand or special-result cones.
  // The existing register path and every other arithmetic service stay live.
  logic [79:0] div_mem_q, div_st0_q;
  logic [3:0] div_bytes_q;
  logic [2:0] div_aluop_q;
  logic div_bug_q;
  logic [79:0] div_a, div_b;
  logic [2:0] div_aluop;
  wire logic mem_arith_cmd = cmd_op inside {
      FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32};

  always_comb begin
    div_aluop = cmd_aluop;
    div_a = (cmd_op == FX_AR_STI_ST0) ? sti_data : st0_data;
    div_b = (cmd_op == FX_AR_STI_ST0) ? st0_data : sti_data;
    if (top_state == TOP_MEMDIV) begin
      div_aluop = div_aluop_q;
      div_a = div_st0_q;
      if (pending_op inside {FX_AR_I16, FX_AR_I32})
        div_b = f_mem_as_int(div_mem_q, div_bytes_q);
      else
        div_b = f_mem_as_float(div_mem_q, div_bytes_q);
    end
  end

  logic [81:0] div_special_raw;
  logic        div_special_hit;
  logic [84:0] div_special_result;
  logic        sqrt_special_hit;
  logic [84:0] sqrt_special_result;
  logic [15:0] sqrt_special_status;
  logic [79:0] cmp_b;
  logic        cmp_signaling;
  logic [15:0] cmp_status;
  logic [3:0]  xam_codes;
  logic [15:0] env_ftw;
  logic [639:0] env_st_regs;
  logic [863:0] env_image32;
  logic [751:0] env_image16;
  logic [15:0] env_load_control, env_load_status;
  logic [2:0] env_load_top;
  logic [7:0] env_load_tag;
  logic [31:0] env_load_fip, env_load_fdp;
  logic [15:0] env_load_fcs, env_load_fds;
  logic [639:0] env_load_regs_phys;
  logic issue_reads_st0, issue_reads_sti, issue_push, issue_pop2;
  logic issue_is_compare, issue_overflow, issue_underflow, issue_stack_fault;

  localparam logic [79:0] QNAN_INDEF = 80'hffffc000000000000000;

`ifndef SYNTHESIS
`ifdef VEN_FP_PERF
  // Simulation-only command-latency attribution.  The shared top deliberately
  // serializes all x87 work; distinguish the cheap response round trip from
  // the one shared ALU/SRT/convert service before changing that contract.
  localparam int FP_PERF_NCLASS = 8;
  localparam logic [2:0] FPPC_IMMEDIATE = 3'd0;
  localparam logic [2:0] FPPC_FAST_ALU  = 3'd1;
  localparam logic [2:0] FPPC_SRT       = 3'd2;
  localparam logic [2:0] FPPC_MISC      = 3'd3;
  localparam logic [2:0] FPPC_BCD_LOAD  = 3'd4;
  localparam logic [2:0] FPPC_BCD_STORE = 3'd5;
  localparam logic [2:0] FPPC_TRANS     = 3'd6;
  localparam logic [2:0] FPPC_STACKFLT  = 3'd7;
  longint unsigned fp_perf_cycles;
  longint unsigned fp_perf_state [8];
  longint unsigned fp_perf_accept [FP_PERF_NCLASS];
  longint unsigned fp_perf_latency [FP_PERF_NCLASS];
  logic             fp_perf_active;
  logic [2:0]       fp_perf_class_q;
  longint unsigned  fp_perf_age;
`ifdef VEN_FP_ARITH_STREAM
  // Four owners include the registered response-observation cycle. These are
  // simulation-only counters, not an extra hardware command/result queue.
  logic [1:0] fp_perf_head, fp_perf_tail;
  logic [2:0] fp_perf_count;
  logic [2:0] fp_perf_owner_class [4];
  longint unsigned fp_perf_owner_cycle [4];
`endif
  // Census the one proposed low-area fast-path candidate separately from the
  // aggregate MISC class before changing its command/response contract.  The
  // plain and pop forms have different architectural commit rules; a stack
  // fault must never be counted as a normal direct-store opportunity.
  longint unsigned fp_perf_fst_m80_plain;
  longint unsigned fp_perf_fst_m80_pop;
  longint unsigned fp_perf_fst_m80_stack_fault;

  function automatic logic [2:0] fp_perf_class;
    begin
      if (issue_stack_fault)
        fp_perf_class = FPPC_STACKFLT;
      else if (((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
                (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
                (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) &&
               is_fast_arith(cmd_aluop))
        fp_perf_class = FPPC_FAST_ALU;
      else if (((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
                (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
                (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) &&
               is_div_arith(cmd_aluop) && (mem_arith_cmd || !div_special_hit))
        fp_perf_class = FPPC_SRT;
      else if ((cmd_op == FX_FSQRT) && !sqrt_special_hit)
        fp_perf_class = FPPC_SRT;
      else if ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1))
        fp_perf_class = FPPC_SRT;
      else if (is_misc_op(cmd_op))
        fp_perf_class = FPPC_MISC;
      else if (cmd_op == FX_FBLD)
        fp_perf_class = FPPC_BCD_LOAD;
      else if (cmd_op == FX_FBSTP)
        fp_perf_class = FPPC_BCD_STORE;
      else if (is_trans_op(cmd_op))
        fp_perf_class = FPPC_TRANS;
      else
        fp_perf_class = FPPC_IMMEDIATE;
    end
  endfunction

  function automatic string fp_perf_class_name(input logic [2:0] c);
    case (c)
      FPPC_IMMEDIATE: fp_perf_class_name = "immediate command";
      FPPC_FAST_ALU:  fp_perf_class_name = "shared add/sub/mul";
      FPPC_SRT:       fp_perf_class_name = "shared SRT";
      FPPC_MISC:      fp_perf_class_name = "shared conversion/store";
      FPPC_BCD_LOAD:  fp_perf_class_name = "shared BCD load";
      FPPC_BCD_STORE: fp_perf_class_name = "shared BCD store";
      FPPC_TRANS:     fp_perf_class_name = "shared transcendental";
      default:         fp_perf_class_name = "stack-fault shortcut";
    endcase
  endfunction
`endif
`endif

`ifdef VEN_FP_ARITH_MEM_FWD
`ifndef VEN_FP_ARITH_FWD
  initial $fatal(1, "VEN_FP_ARITH_MEM_FWD requires registered arithmetic forwarding");
`endif
`endif
  wire logic accept = cmd_valid & cmd_ready;
`ifdef VEN_FP_ARITH_FWD
`ifndef VEN_FP_ARITH_STREAM
  initial $fatal(1, "VEN_FP_ARITH_FWD requires VEN_FP_ARITH_STREAM");
`endif
`endif

`ifdef VEN_FP_ARITH_STREAM
  // Metadata follows the three registered arithmetic stages; the existing
  // state-file write port consumes stage 2 alongside alu_done. No extra
  // arithmetic unit, speculative stack map or out-of-order write.
  logic [2:0] arith_owner_valid;
  logic [2:0] arith_owner_dst [3];
  logic [2:0] arith_owner_pop;
  logic arith_stream_eligible, arith_stream_hazard;
  // P54's shared multiply resource cannot start consecutive FMULs.  This
  // interlock is at command acceptance, not at result writeback: independent
  // integer or non-multiply FP work can still occupy the intervening clock.
  logic arith_mul_accepted_last_cycle;
  wire logic arith_mul_interval_busy = arith_mul_accepted_last_cycle &&
      (cmd_aluop == 3'd1) &&
      ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
       (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
       (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32));
  logic [2:0] arith_cmd_dst;
  assign arith_cmd_dst = (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
`ifdef VEN_FP_ARITH_FWD
  logic arith_forward_eligible, arith_forward_st0, arith_forward_sti;
  logic [79:0] arith_operand_st0, arith_operand_sti;
  // alu_result is the existing final REGISTER. Its owner commits on the
  // same edge that a dependent command may capture these operands. Never
  // forward an earlier arithmetic cone, a popped stack, or an empty source.
  assign arith_forward_eligible = (top_state == TOP_ALU) && alu_done &&
      arith_owner_valid[2] && !arith_owner_pop[2] && arith_stream_eligible &&
      ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0)
`ifdef VEN_FP_ARITH_MEM_FWD
       // The memory operand is already command-owned. Forward only ST0;
       // alu_b remains the existing format-converted memory value. These
       // forms neither read STi nor change the logical stack mapping.
       || (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64)
       || (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)
`endif
      );
  assign arith_forward_st0 = arith_forward_eligible &&
                             (arith_owner_dst[2] == 3'd0);
  assign arith_forward_sti = arith_forward_eligible && issue_reads_sti &&
                             (arith_owner_dst[2] == cmd_sti);
  assign arith_operand_st0 = arith_forward_st0 ? alu_result[79:0] : st0_data;
  assign arith_operand_sti = arith_forward_sti ? alu_result[79:0] : sti_data;
`endif
  always_comb begin
    arith_stream_hazard = 1'b0;
    for (int i=0; i<3; i++) begin
      if (arith_owner_valid[i] &&
          (arith_owner_pop[i] || arith_owner_dst[i] == 3'd0 ||
           arith_owner_dst[i] == arith_cmd_dst ||
           (issue_reads_sti && arith_owner_dst[i] == cmd_sti))
`ifdef VEN_FP_ARITH_FWD
          // Resolve only stage 2, and only if EVERY aliased read takes the
          // registered result. Register arithmetic's WAW destination is also
          // a source; it cannot bypass the corresponding RAW select.
          && !((i == 2) && arith_forward_eligible &&
               ((arith_owner_dst[i] != 3'd0) || arith_forward_st0) &&
               ((!issue_reads_sti || arith_owner_dst[i] != cmd_sti) ||
                arith_forward_sti))
`endif
         )
        arith_stream_hazard = 1'b1;
    end
  end
  assign arith_stream_eligible = !cmd_pop && !issue_stack_fault &&
      (fctrl_o[5:0] == 6'h3f) && !fstat_o[7] &&
      is_fast_arith(cmd_aluop) &&
      ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
       (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
       (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32));
  assign cmd_ready = !arith_mul_interval_busy &&
      ((top_state == TOP_IDLE) ||
       ((top_state == TOP_ALU) && arith_stream_eligible && !arith_stream_hazard));
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      arith_mul_accepted_last_cycle <= 1'b0;
      arith_owner_valid <= '0;
      arith_owner_pop <= '0;
      for (int i=0; i<3; i++) arith_owner_dst[i] <= '0;
    end else begin
      // A masked stack-fault command is accepted but never starts the ALU;
      // it must not consume the multiplier's initiation slot.
      arith_mul_accepted_last_cycle <= alu_start && (cmd_aluop == 3'd1);
      arith_owner_valid <= {arith_owner_valid[1:0], alu_start};
      arith_owner_pop <= {arith_owner_pop[1:0], cmd_pop};
      arith_owner_dst[0] <= arith_cmd_dst;
      arith_owner_dst[1] <= arith_owner_dst[0];
      arith_owner_dst[2] <= arith_owner_dst[1];
`ifndef SYNTHESIS
      if ((top_state == TOP_ALU) && (alu_done != arith_owner_valid[2]))
        $fatal(1, "FP arithmetic result lost its owner");
`ifdef VEN_FP_ARITH_FWD
      if (accept && arith_forward_eligible) begin
        if ((arith_owner_dst[2] == 3'd0) &&
            ((cmd_op == FX_AR_STI_ST0 ? alu_b : alu_a) != alu_result[79:0]))
          $fatal(1, "FP_ARITH_FWD: ST0 alias did not select registered result");
        if (issue_reads_sti && (arith_owner_dst[2] == cmd_sti) &&
            ((cmd_op == FX_AR_STI_ST0 ? alu_a : alu_b) != alu_result[79:0]))
          $fatal(1, "FP_ARITH_FWD: STi alias did not select registered result");
      end
`endif
`endif
    end
  end
`else
  assign cmd_ready = (top_state == TOP_IDLE);
`endif
  assign busy      = (top_state != TOP_IDLE);

  ven_fp_state u_state (
      .clk(clk),
      .rst_n(rst_n),
`ifdef VEN_SNAPSHOT_RESTORE
      .init_restore(init_restore),
      .init_top(init_top), .init_status(init_status),
      .init_control(init_control), .init_tag(init_tag),
      .init_fip(init_fip), .init_fcs(init_fcs),
      .init_fdp(init_fdp), .init_fds(init_fds),
      .init_regs_phys(init_regs_phys),
`endif
      .rd0_idx(3'd0),
      .rd1_idx(state_rd1_idx),
      .rd0_data(st0_data),
      .rd1_data(sti_data),
      .rd0_empty(st0_empty),
      .rd1_empty(sti_empty),
      .top_o(ftop_o),
      .status_o(fstat_o),
      .control_o(fctrl_o),
      .tag_o(fptag_o),
      .fip_o(fip_o),
      .fcs_o(fcs_o),
      .fdp_o(fdp_o),
      .fds_o(fds_o),
      .phys_flat_o(fpr_phys_flat_o),
      .st_flat_o(st_flat_o),
      .commit_init(c_init),
      .commit_push(c_push),
      .push_data(c_push_data),
      .commit_write(c_write),
      .write_idx(c_write_idx),
      .write_data(c_write_data),
      .write_mark_valid(c_write_valid),
      .commit_swap(c_swap),
      .swap_idx(c_swap_idx),
      .commit_swap_materialize_empty(c_swap_materialize_empty),
      .commit_pop(c_pop),
      .commit_free(c_free),
      .free_idx(c_free_idx),
      .commit_inc_top(c_inc_top),
      .commit_dec_top(c_dec_top),
      .commit_status(c_status),
      .status_data(c_status_data),
      .commit_control(c_control),
      .control_data(c_control_data),
      .commit_eptr(c_eptr),
      .eptr_fip(c_env ? env_load_fip : cmd_fip),
      .eptr_fcs(c_env ? env_load_fcs : cmd_fcs),
      .commit_dptr(c_dptr),
      .dptr_fdp(c_env ? env_load_fdp : cmd_fdp),
      .dptr_fds(c_env ? env_load_fds : cmd_fds),
      .commit_env(c_env),
      .env_control(c_env_control),
      .env_top(c_env_top),
      .env_status(c_env_status),
      .env_tag(c_env_tag),
      .commit_env_regs(c_env_regs),
      .env_regs_phys(c_env_regs_phys)
  );

  // Ordinary arithmetic and every transcendental polynomial borrow this one
  // registered floatx80 add/multiply pipeline.  TOP_ALU and TOP_TRANS are
  // mutually exclusive, so the mux is an assertion of ownership rather than
  // an arbitration point on the setup path.
  wire logic shared_fx_start = (top_state == TOP_TRANS)
                             ? trans_fx_req : alu_start;
  wire logic [2:0] shared_fx_subop = (top_state != TOP_TRANS) ? alu_subop
      : (trans_fx_op == 2'd0) ? 3'd0
      : (trans_fx_op == 2'd1) ? 3'd1
      : (trans_fx_op == 2'd2) ? 3'd4 : 3'd5;

  ven_fp_alu u_shared_fx (
      .clk(clk),
      .rst_n(rst_n),
      .start(shared_fx_start),
      .subop(shared_fx_subop),
      .operand_a((top_state == TOP_TRANS) ? trans_fx_a : alu_a),
      .operand_b((top_state == TOP_TRANS) ? trans_fx_b : alu_b),
      .rc((top_state == TOP_TRANS) ? trans_fx_rc : fctrl_o[11:10]),
      .pc((top_state == TOP_TRANS) ? trans_fx_pc : fctrl_o[9:8]),
      .busy(alu_busy),
      .done(alu_done),
      .commit_next(alu_commit_next),
      .result(alu_result),
      .rounded_up(alu_rounded_up)
  );

  ven_fp_misc u_misc (
      .clk(clk),
      .rst_n(rst_n),
      .start(misc_start),
      .op(cmd_op),
      .operand_a(st0_data),
      .operand_b(sti_data),
      .rc(fctrl_o[11:10]),
      .pc(fctrl_o[9:8]),
      .fist_bug(cmd_fist_bug),
      .busy(misc_busy),
      .done(misc_done),
      .value(misc_value),
      .flag_ie(misc_ie),
      .flag_oe(misc_oe),
      .flag_ue(misc_ue),
      .flag_pe(misc_pe),
      .rounded_up(misc_rounded_up),
      .tiny_nonzero(misc_tiny_nonzero)
  );

  ven_bcd_to_fp u_bcd_load (
      .clk(clk),
      .rst_n(rst_n),
      .start(bcd_load_start),
      .bcd(cmd_mem),
      .busy(bcd_load_busy),
      .done(bcd_load_done),
      .result(bcd_load_result)
  );

  ven_bcd u_bcd_store (
      .clk(clk),
      .rst_n(rst_n),
      .start(bcd_store_start),
      .v(st0_data),
      .rc(fctrl_o[11:10]),
      .busy(bcd_store_busy),
      .done(bcd_store_done),
      .result(bcd_store_result)
  );

  ven_fp_trans u_trans (
      .clk(clk), .rst_n(rst_n), .start(trans_start), .op(cmd_op),
      .x(st0_data), .y(sti_data), .rc(fctrl_o[11:10]),
      .fx_req(trans_fx_req), .fx_op(trans_fx_op),
      .fx_a(trans_fx_a), .fx_b(trans_fx_b),
      .fx_rc(trans_fx_rc), .fx_pc(trans_fx_pc),
      .fx_vld(alu_done && (top_state == TOP_TRANS)),
      .fx_result(alu_result[79:0]), .fx_pe(alu_result[80]),
      .divide_start(trans_divide_start),
      .divide_a(trans_divide_a), .divide_b(trans_divide_b),
      .divide_rc(trans_divide_rc),
      .divide_done(srt_done), .divide_result(srt_result[79:0]),
      .busy(trans_busy), .done(trans_done),
      .primary(trans_primary), .secondary(trans_secondary),
      .flag_c2(trans_c2), .flag_ie(trans_ie), .flag_pe(trans_pe)
  );

  fpu_srt_div u_srt (
      .clk(clk),
      .rst_n(rst_n),
      .start(srt_start),
      .mode(srt_mode),
      .prem1(cmd_op == FX_FPREM1),
      .rem_underflow_mask(fctrl_o[4]),
      .a(srt_a),
      .b(srt_b),
`ifdef VEN_SRT_REM_OPERAND_SPLIT
      .rem_a(st0_data),
      .rem_b(sti_data),
`endif
      .rc(srt_rc),
      .pc(srt_pc),
      .buggy(srt_bug_q),
      .busy(srt_busy),
      .done(srt_done),
      .result(srt_result),
      .rounded_up(srt_rounded_up),
      .rem_q012(srt_rem_q012),
      .rem_c2(srt_rem_c2),
      .rem_ie(srt_rem_ie)
  );

  function automatic logic is_fast_arith(input logic [2:0] op);
    return (op == 3'd0) || (op == 3'd1) ||
           (op == 3'd4) || (op == 3'd5);
  endfunction

  function automatic logic is_div_arith(input logic [2:0] op);
    return (op == 3'd6) || (op == 3'd7);
  endfunction

  function automatic logic is_misc_op(input fxop_e op);
    unique case (op)
      FX_FST_M32, FX_FST_M64, FX_FST_M80,
      FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
      FX_FRNDINT, FX_FSCALE: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic is_misc_store(input fxop_e op);
    unique case (op)
      FX_FST_M32, FX_FST_M64, FX_FST_M80,
      FX_FIST_M16, FX_FIST_M32, FX_FIST_M64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic is_trans_op(input fxop_e op);
    return (op == FX_F2XM1) ||
           (op == FX_FPATAN) || (op == FX_FYL2X) ||
           (op == FX_FYL2XP1) ||
           (op == FX_FSIN) || (op == FX_FCOS) ||
           (op == FX_FSINCOS) || (op == FX_FPTAN);
  endfunction

  // Operand-validity descriptors are centralized here so immediate and
  // deferred engines cannot drift.  This is the command-level equivalent of
  // the proven fpu_writeback H-11/H-16 stack-fault matrix.
  always_comb begin
    issue_reads_st0 = 1'b0;
    issue_reads_sti = 1'b0;
    issue_push      = 1'b0;
    issue_pop2      = 1'b0;
    issue_is_compare= 1'b0;

    unique case (cmd_op)
      FX_FLDCONST, FX_FLD_M32, FX_FLD_M64, FX_FLD_M80,
      FX_FILD_M16, FX_FILD_M32, FX_FILD_M64, FX_FBLD:
        issue_push = 1'b1;
      FX_FLD_STI: begin issue_reads_sti = 1'b1; issue_push = 1'b1; end
      FX_FSINCOS, FX_FPTAN: begin issue_reads_st0 = 1'b1; issue_push = 1'b1; end

      FX_AR_ST0_STI, FX_AR_STI_ST0:
        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end
      FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32,
      FX_FCOM_M32, FX_FCOM_M64, FX_FTST,
      FX_FICOM_M16, FX_FICOM_M32,
      FX_FST_M32, FX_FST_M64, FX_FST_M80,
      FX_FIST_M16, FX_FIST_M32, FX_FIST_M64, FX_FBSTP,
      FX_FABS, FX_FCHS, FX_FSQRT, FX_FRNDINT,
      FX_F2XM1, FX_FSIN, FX_FCOS:
        issue_reads_st0 = 1'b1;

      FX_FCOM_STI, FX_FUCOM_STI:
        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end
      // ST(i) is a write destination, including when its tag is empty.
      FX_FST_STI: issue_reads_st0 = 1'b1;
      FX_FCOMPP, FX_FUCOMPP: begin
        issue_reads_st0 = 1'b1;
        issue_reads_sti = 1'b1;
        issue_pop2      = 1'b1;
      end
      FX_FXCH:
        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end
      FX_FPATAN, FX_FYL2X, FX_FYL2XP1,
      FX_FSCALE, FX_FPREM, FX_FPREM1:
        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end
      default: begin end
    endcase

    unique case (cmd_op)
      FX_FCOM_M32, FX_FCOM_M64, FX_FCOM_STI, FX_FUCOM_STI,
      FX_FCOMPP, FX_FUCOMPP, FX_FTST, FX_FICOM_M16, FX_FICOM_M32:
        issue_is_compare = 1'b1;
      default: begin end
    endcase

    issue_overflow = issue_push && !fptag_o[ftop_o - 3'd1];
    issue_underflow = (issue_reads_st0 && st0_empty) ||
                      (issue_reads_sti && sti_empty) ||
                      (issue_pop2 &&
                       (fptag_o[ftop_o] || fptag_o[ftop_o + 3'd1]));
    issue_stack_fault = issue_overflow || issue_underflow;
  end

  always_comb begin
    state_rd1_idx = cmd_sti;
    if ((cmd_op == FX_FCOMPP) || (cmd_op == FX_FUCOMPP) ||
        (cmd_op == FX_FSCALE) || (cmd_op == FX_FPREM) ||
        (cmd_op == FX_FPREM1) || (cmd_op == FX_FPATAN) ||
        (cmd_op == FX_FYL2X) || (cmd_op == FX_FYL2XP1))
      state_rd1_idx = 3'd1;
  end

  // Operand selection mirrors fpu_writeback's proven instruction forms.
  always_comb begin
    alu_subop = cmd_aluop;
`ifdef VEN_FP_ARITH_FWD
    alu_a = arith_operand_st0;
    alu_b = arith_operand_sti;
`else
    alu_a = st0_data;
    alu_b = sti_data;
`endif
    unique case (cmd_op)
      FX_AR_STI_ST0: begin
`ifdef VEN_FP_ARITH_FWD
        alu_a = arith_operand_sti;
        alu_b = arith_operand_st0;
`else
        alu_a = sti_data;
        alu_b = st0_data;
`endif
      end
      FX_AR_M32, FX_AR_M64: begin
        alu_b = f_mem_as_float(cmd_mem, cmd_mem_bytes);
      end
      FX_AR_I16, FX_AR_I32: begin
        alu_b = f_mem_as_int(cmd_mem, cmd_mem_bytes);
      end
      default: begin end
    endcase
  end

  // Invalid classification needs the source encoding, not normalized data.
  // Every signed integer converts to a finite exact floatx80 value; float32
  // and float64 NaN classes are invariant under the existing widening.
  // Preserve the default floatx80 and quiet/register forms for every size.
  // Numeric condition codes still use the original shared compare datapath.
  function automatic logic compare_invalid(
      input fxop_e op, input logic [79:0] a, input logic [79:0] sti,
      input logic [79:0] memory, input logic [3:0] bytes);
    logic memory_nan;
    unique case (bytes)
      4'd4: memory_nan = (&memory[30:23]) && (|memory[22:0]);
      4'd8: memory_nan = (&memory[62:52]) && (|memory[51:0]);
      default: memory_nan = fx_is_nan(memory);
    endcase
    unique case (op)
      FX_FCOM_M32, FX_FCOM_M64:
        return fx_is_nan(a) || memory_nan;
      FX_FICOM_M16, FX_FICOM_M32, FX_FTST:
        return fx_is_nan(a);
      FX_FUCOM_STI, FX_FUCOMPP:
        return fx_is_snan(a) || fx_is_snan(sti);
      default:
        return fx_is_nan(a) || fx_is_nan(sti);
    endcase
  endfunction

  // A single shared compare/classify cone feeds every compare opcode.
  always_comb begin
    cmp_b         = sti_data;
    cmp_signaling = 1'b1;
    unique case (cmd_op)
      FX_FCOM_M32, FX_FCOM_M64:
        cmp_b = f_mem_as_float(cmd_mem, cmd_mem_bytes);
      FX_FUCOM_STI, FX_FUCOMPP:
        cmp_signaling = 1'b0;
      FX_FTST:
        cmp_b = 80'd0;
      FX_FICOM_M16, FX_FICOM_M32:
        cmp_b = f_mem_as_int(cmd_mem, cmd_mem_bytes);
      default: begin end
    endcase
    cmp_status = apply_cmp(fstat_o, fcom_codes(st0_data, cmp_b),
                           compare_invalid(cmd_op, st0_data, sti_data, cmd_mem, cmd_mem_bytes));
    xam_codes = fxam_codes(st0_data, st0_empty);
  end

  // Canonical FNSTENV/FNSAVE images.  Keeping the image construction here
  // gives the integration adapter one serialized payload instead of exposing
  // eight live register buses to the CPU datapath.
  always_comb begin
    env_ftw = 16'd0;
    for (int p = 0; p < 8; p++)
      env_ftw[p*2 +: 2] = ftw_field(fptag_o[p],
                                    fpr_phys_flat_o[p*80 +: 80]);
    env_st_regs = st_flat_o;
    env_image32 = {
        env_st_regs,
        // Intel P5 Vol. 3 figure 6-7: real/V86 32-bit pointers are
        // split across words, unlike the protected-mode offset/selector pair.
        cmd_real_mode ? {4'd0, fdp_o[31:16], 12'd0} : {16'd0, fds_o},
        cmd_real_mode ? {16'd0, fdp_o[15:0]} : fdp_o,
        cmd_real_mode ? {4'd0, fip_o[31:16], 12'd0} : {5'd0, 11'd0, fcs_o},
        cmd_real_mode ? {16'd0, fip_o[15:0]} : fip_o,
        {16'd0, env_ftw},
        {16'd0, (fstat_o & ~16'h3800) | ({13'd0, ftop_o} << 11)},
        {16'd0, fctrl_o}
    };
    env_image16 = {
        env_st_regs,
        cmd_real_mode ? {fdp_o[19:16], 12'd0} : fds_o,
        fdp_o[15:0],
        cmd_real_mode ? {fip_o[19:16], 1'b0, 11'd0} : fcs_o,
        fip_o[15:0],
        env_ftw,
        (fstat_o & ~16'h3800) | ({13'd0, ftop_o} << 11),
        fctrl_o
    };
  end

  // Canonical FLDENV/FRSTOR decode.  The input image is little-endian packed:
  // its low bits are the first bytes at the architectural memory address.
  always_comb begin
    logic [15:0] load_sw, load_ftw;
    int logical_index;
    load_sw  = cmd_env16 ? cmd_env_image[31:16]
                         : cmd_env_image[47:32];
    load_ftw = cmd_env16 ? cmd_env_image[47:32]
                         : cmd_env_image[79:64];
    // Intel P5 Vol. 3, figures 6-6 through 6-9. Real/V86 images
    // encode linear pointers, not selectors. Ignore only reserved bits.
    if (cmd_env16) begin
      env_load_fip = {16'd0, cmd_env_image[63:48]};
      env_load_fdp = {16'd0, cmd_env_image[95:80]};
      env_load_fcs = cmd_env_image[79:64];
      env_load_fds = cmd_env_image[111:96];
      if (cmd_real_mode) begin
        env_load_fip = {12'd0, cmd_env_image[79:76], cmd_env_image[63:48]};
        env_load_fdp = {12'd0, cmd_env_image[111:108], cmd_env_image[95:80]};
        env_load_fcs = 16'd0;
        env_load_fds = 16'd0;
      end
    end else begin
      env_load_fip = cmd_env_image[127:96];
      env_load_fdp = cmd_env_image[191:160];
      env_load_fcs = cmd_env_image[143:128];
      env_load_fds = cmd_env_image[207:192];
      if (cmd_real_mode) begin
        env_load_fip = {cmd_env_image[155:140], cmd_env_image[111:96]};
        env_load_fdp = {cmd_env_image[219:204], cmd_env_image[175:160]};
        env_load_fcs = 16'd0;
        env_load_fds = 16'd0;
      end
    end
    env_load_control = cmd_env_image[15:0];
    env_load_top     = load_sw[13:11];
    env_load_status  = (load_sw & ~16'h3800 & ~16'h8000) |
                       (load_sw[7] ? 16'h8000 : 16'd0);
    for (int p = 0; p < 8; p++)
      env_load_tag[p] = (load_ftw[p*2 +: 2] == 2'b11);
    env_load_regs_phys = 640'd0;
    for (int p = 0; p < 8; p++) begin
      logical_index = (p - int'(load_sw[13:11])) & 7;
      if (cmd_env16)
        env_load_regs_phys[p*80 +: 80] =
            cmd_env_image[112 + logical_index*80 +: 80];
      else
        env_load_regs_phys[p*80 +: 80] =
            cmd_env_image[224 + logical_index*80 +: 80];
    end
  end

  // Cheap divide/sqrt exceptional cases.  Normal finite work goes only to the
  // iterative SRT engine; no behavioral wide divider is reachable here.
  always_comb begin
    div_special_raw    = f_special(div_aluop, div_a, div_b);
    div_special_hit    = 1'b0;
    div_special_result = '0;
    if (div_special_raw[81]) begin
      div_special_hit    = 1'b1;
      div_special_result = {div_special_raw[80], 4'b0000,
                            div_special_raw[79:0]};
    end else if (f_zero_over_zero(div_aluop, div_a, div_b)) begin
      div_special_hit    = 1'b1;
      div_special_result = {1'b1, 4'b0000,
                            80'hffffc000000000000000};
    end else if (f_div_by_zero(div_aluop, div_a, div_b)) begin
      div_special_hit    = 1'b1;
      div_special_result = {1'b0, 1'b1, 3'b000,
                            fx_make(div_a[79] ^ div_b[79], 15'h7fff,
                                    64'h8000000000000000)};
    end

    sqrt_special_hit    = 1'b0;
    sqrt_special_result = '0;
    sqrt_special_status = fstat_o;
    if (fx_is_snan(st0_data)) begin
      sqrt_special_hit    = 1'b1;
      sqrt_special_result = {1'b1, 4'b0000, fx_quietize(st0_data)};
      sqrt_special_status = fstat_o | 16'h0001;
    end else if (fx_is_nan(st0_data)) begin
      sqrt_special_hit    = 1'b1;
      sqrt_special_result = {5'b00000, st0_data};
    end else if (st0_data[79] && !fx_is_zero(st0_data)) begin
      sqrt_special_hit    = 1'b1;
      sqrt_special_result = {1'b1, 4'b0000,
                             80'hffffc000000000000000};
      sqrt_special_status = (fstat_o & ~16'h4700) | 16'h0401;
    end else if (fx_is_zero(st0_data) || fx_is_inf(st0_data)) begin
      sqrt_special_hit    = 1'b1;
      sqrt_special_result = {5'b00000, st0_data};
    end
  end

  // Rounding controls are live throughout SRT execution. Command admission
  // cannot win while TOP_TRANS owns the unit (cmd_ready is low there), so
  // keep its long decode/operand cone out of these controls. Do not capture
  // RC/PC: a borrowed transcendental request's PC=64 override ends with the
  // request pulse, retaining the existing subsequent live-CW behavior.
  always_comb begin
    srt_rc    = fctrl_o[11:10];
    srt_pc    = fctrl_o[9:8];
    if ((top_state == TOP_TRANS) && trans_divide_start) begin
      srt_rc  = trans_divide_rc;
      srt_pc  = 2'b11;
    end
  end

`ifdef VEN_SRT_PAYLOAD_SELECT
  always_comb begin
    srt_start = 1'b0;
    if (top_state == TOP_MEMDIV) begin
      srt_start = !div_special_hit;
    end else if (accept && !issue_stack_fault &&
        ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
         (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
         (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) &&
        is_div_arith(cmd_aluop) && !mem_arith_cmd && !div_special_hit) begin
      srt_start = 1'b1;
    end else if (accept && !issue_stack_fault &&
                 (cmd_op == FX_FSQRT) && !sqrt_special_hit) begin
      srt_start = 1'b1;
    end else if (accept && !issue_stack_fault &&
                 ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1))) begin
      srt_start = 1'b1;
    end else if ((top_state == TOP_TRANS) && trans_divide_start) begin
      srt_start = 1'b1;
    end else if ((top_state == TOP_TRANS) && trans_done &&
                 (pending_op == FX_FPTAN) && !trans_c2) begin
      // FPTAN's quotient uses the same SRT divider as FDIV/FPREM.  The trig
      // sequencer supplies captured sine/cosine values on its done cycle.
      srt_start = 1'b1;
    end
  end

  // Present operands before the late accept/stack/special-case guard.
  // The engine samples these fields only on start. TOP_TRANS cannot accept
  // an external command, and its divide request has priority over FPTAN done.
  always_comb begin
    srt_mode = 2'd0;
    srt_a = (div_aluop == 3'd7) ? div_b : div_a;
    srt_b = (div_aluop == 3'd7) ? div_a : div_b;
    if (top_state == TOP_MEMDIV) begin
      // Captured divide owner wins over a changing, unaccepted command bus.
      srt_mode = 2'd0;
    end else if (top_state == TOP_TRANS) begin
      if (trans_divide_start) begin
        srt_a = trans_divide_a;
        srt_b = trans_divide_b;
      end else begin
        srt_a = trans_primary;
        srt_b = trans_secondary;
      end
    end else if (cmd_op == FX_FSQRT) begin
      srt_mode = 2'd1;
      srt_a = st0_data;
      srt_b = 80'd0;
    end else if ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1)) begin
      srt_mode = 2'd2;
      srt_a = st0_data;
      srt_b = sti_data;
    end
  end

`else
  always_comb begin
    srt_start = 1'b0;
    srt_mode  = 2'd0;
    srt_a     = (div_aluop == 3'd7) ? div_b : div_a;
    srt_b     = (div_aluop == 3'd7) ? div_a : div_b;
    if (top_state == TOP_MEMDIV) begin
      srt_start = !div_special_hit;
    end else if (accept && !issue_stack_fault &&
        ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
         (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
         (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) &&
        is_div_arith(cmd_aluop) && !mem_arith_cmd && !div_special_hit) begin
      srt_start = 1'b1;
      srt_mode  = 2'd0;
    end else if (accept && !issue_stack_fault &&
                 (cmd_op == FX_FSQRT) && !sqrt_special_hit) begin
      srt_start = 1'b1;
      srt_mode  = 2'd1;
      srt_a     = st0_data;
      srt_b     = 80'd0;
    end else if (accept && !issue_stack_fault &&
                 ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1))) begin
      srt_start = 1'b1;
      srt_mode  = 2'd2;
      srt_a     = st0_data;
      srt_b     = sti_data;
    end else if ((top_state == TOP_TRANS) && trans_divide_start) begin
      srt_start = 1'b1;
      srt_mode  = 2'd0;
      srt_a     = trans_divide_a;
      srt_b     = trans_divide_b;
    end else if ((top_state == TOP_TRANS) && trans_done &&
                 (pending_op == FX_FPTAN) && !trans_c2) begin
      // FPTAN's quotient uses the same SRT divider as FDIV/FPREM.  The trig
      // sequencer supplies captured sine/cosine values on its done cycle.
      srt_start = 1'b1;
      srt_mode  = 2'd0;
      srt_a     = trans_primary;
      srt_b     = trans_secondary;
    end
  end
`endif

`ifdef VEN_SRT_REM_OPERAND_SPLIT
`ifndef SYNTHESIS
  // Check the actual shared-top operand/command mux, not merely the standalone
  // arithmetic engine. No new start, permission or exceptional-case bypass.
  always_ff @(posedge clk) if (rst_n && srt_start && srt_mode == 2'd2)
    assert (srt_a === st0_data && srt_b === sti_data)
      else $fatal(1, "SRT-REM-OPERAND: architectural operand owner changed");
`endif
`endif

  // All architectural mutation is concentrated in this commit decoder.
  always_comb begin
    c_init       = 1'b0;
    c_push       = 1'b0;
    c_push_data  = 80'd0;
    c_write      = 1'b0;
    c_write_idx  = 3'd0;
    c_write_data = 80'd0;
    c_write_valid= 1'b0;
    c_swap       = 1'b0;
    c_swap_idx   = 3'd0;
    c_swap_materialize_empty = 1'b0;
    c_pop        = 2'd0;
    c_free       = 1'b0;
    c_free_idx   = 3'd0;
    c_inc_top    = 1'b0;
    c_dec_top    = 1'b0;
    c_status     = 1'b0;
    c_status_data= fstat_o;
    c_control    = 1'b0;
    c_control_data = fctrl_o;
    c_eptr       = accept && cmd_update_fip;
    c_dptr       = accept && cmd_update_fdp;
    c_env        = 1'b0;
    c_env_control= 16'd0;
    c_env_top    = 3'd0;
    c_env_status = 16'd0;
    c_env_tag    = 8'hff;
    c_env_regs   = 1'b0;
    c_env_regs_phys = 640'd0;
    alu_start    = 1'b0;
    misc_start   = 1'b0;
    bcd_load_start  = 1'b0;
    bcd_store_start = 1'b0;
    trans_start     = 1'b0;

    if (accept) begin
      unique case (cmd_op)
        FX_FNINIT: c_init = 1'b1;
        FX_FNCLEX: begin
          c_status      = 1'b1;
          c_status_data = fstat_o & 16'h7f00;
        end
        FX_FNOP, FX_FWAIT: begin end

        FX_FLDCONST: begin
          c_push      = 1'b1;
          c_push_data = fconst(cmd_constant);
        end
        FX_FLD_STI: begin
          c_push      = 1'b1;
          c_push_data = sti_data;
        end
        FX_FLD_M32, FX_FLD_M64, FX_FLD_M80: begin
          c_push      = 1'b1;
          c_push_data = f_mem_as_float(cmd_mem, cmd_mem_bytes);
        end
        FX_FILD_M16, FX_FILD_M32, FX_FILD_M64: begin
          c_push      = 1'b1;
          c_push_data = f_mem_as_int(cmd_mem, cmd_mem_bytes);
        end

        FX_FXCH: begin
          c_swap     = 1'b1;
          c_swap_idx = cmd_sti;
        end
        FX_FST_STI: begin
          c_write       = 1'b1;
          c_write_idx   = cmd_sti;
          c_write_data  = st0_data;
          c_write_valid = 1'b1;
          c_pop         = cmd_pop ? 2'd1 : 2'd0;
          // No format conversion: register FST/FSTP cannot round up.
          c_status      = 1'b1;
          c_status_data = fstat_o & ~16'h0200;
        end
        FX_FFREE: begin
          c_free     = 1'b1;
          c_free_idx = cmd_sti;
        end
        FX_FINCSTP: begin
          c_inc_top     = 1'b1;
          c_status      = 1'b1;
          c_status_data = fstat_o & ~16'h4700;
        end
        FX_FDECSTP: begin
          c_dec_top     = 1'b1;
          c_status      = 1'b1;
          c_status_data = fstat_o & ~16'h4700;
        end
        FX_FABS: begin
          c_write      = 1'b1;
          c_write_idx  = 3'd0;
          c_write_data = {1'b0, st0_data[78:0]};
        end
        FX_FCHS: begin
          c_write      = 1'b1;
          c_write_idx  = 3'd0;
          c_write_data = {~st0_data[79], st0_data[78:0]};
        end
        FX_FLDCW: begin
          c_control      = 1'b1;
          c_control_data = cmd_mem[15:0];
        end

        FX_FNSTENV: begin
          // The response payload is captured by the sequential response block
          // from the pre-edge state.  Architecturally, FNSTENV then masks all
          // exception classes.
          c_control      = 1'b1;
          c_control_data = fctrl_o | 16'h003f;
        end
        FX_FNSAVE: begin
          // The full response image likewise observes the pre-FNINIT state.
          c_init = 1'b1;
        end
        FX_FLDENV, FX_FRSTOR: begin
          // Commit pointers with the fully assembled environment, never
          // from the administrative instruction's own command address.
          c_eptr        = 1'b1;
          c_dptr        = 1'b1;
          c_env         = 1'b1;
          c_env_control = env_load_control;
          c_env_top     = env_load_top;
          c_env_status  = env_load_status;
          c_env_tag     = env_load_tag;
          if (cmd_op == FX_FRSTOR) begin
            c_env_regs      = 1'b1;
            c_env_regs_phys = env_load_regs_phys;
          end
        end

        FX_FST_M32, FX_FST_M64, FX_FST_M80,
        FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
        FX_FRNDINT, FX_FSCALE: misc_start = 1'b1;

        FX_FBLD:  bcd_load_start  = 1'b1;
        FX_FBSTP: bcd_store_start = 1'b1;

        FX_F2XM1, FX_FPATAN, FX_FYL2X, FX_FYL2XP1,
        FX_FSIN, FX_FCOS, FX_FSINCOS, FX_FPTAN:
          trans_start = 1'b1;

        FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64,
        FX_FUCOM_STI, FX_FTST, FX_FICOM_M16, FX_FICOM_M32: begin
          c_status      = 1'b1;
          c_status_data = cmp_status;
          c_pop         = cmd_pop ? 2'd1 : 2'd0;
        end
        FX_FCOMPP, FX_FUCOMPP: begin
          c_status      = 1'b1;
          c_status_data = cmp_status;
          c_pop         = 2'd2;
        end
        FX_FXAM: begin
          c_status = 1'b1;
          c_status_data = (fstat_o & ~16'h4700) |
                          ({15'd0,xam_codes[3]} << 14) |
                          ({15'd0,xam_codes[2]} << 10) |
                          ({15'd0,xam_codes[1]} << 9)  |
                          ({15'd0,xam_codes[0]} << 8);
        end

        FX_AR_ST0_STI, FX_AR_STI_ST0,
        FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32: begin
          if (is_fast_arith(cmd_aluop))
            alu_start = 1'b1;
          else if (is_div_arith(cmd_aluop) && !mem_arith_cmd && div_special_hit) begin
            c_write       = 1'b1;
            c_write_idx   = (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
            c_write_data  = div_special_result[79:0];
            c_status      = 1'b1;
            c_status_data = f_arith_fstat(fstat_o, div_special_result);
            c_status_data[9] = 1'b0;
            c_pop         = cmd_pop ? 2'd1 : 2'd0;
          end
        end
        FX_FSQRT: begin
          if (sqrt_special_hit) begin
            c_write       = 1'b1;
            c_write_idx   = 3'd0;
            c_write_data  = sqrt_special_result[79:0];
            c_status      = 1'b1;
            c_status_data = sqrt_special_status;
            c_status_data[9] = 1'b0;
          end
        end
        default: begin end
      endcase

      // P54 table 6-4: direct FLD/FILD/constant loads clear C1.
      // Only direct loads assert c_push here. Deferred arithmetic and
      // transcendental pushes commit below, under their own owner.
      // Keep this BEFORE #IS: a full-stack push must still report C1=1.
      // P54 table 6-4 also defines zero C1 for FABS/FCHS/FXCH.
      if (c_push || c_swap ||
          (cmd_op == FX_FABS) || (cmd_op == FX_FCHS)) begin
        c_status = 1'b1;
        c_status_data[9] = 1'b0;
      end

      // Stack faults override the ordinary issue path.  This mirrors the
      // proven writeback matrix: IE|SF are unconditional, C1 distinguishes
      // overflow from underflow, masked comparisons answer unordered, and an
      // unmasked #IS suppresses every architectural action except status and
      // the already-resolved FIP/FDP pointer commits.
      if (issue_stack_fault) begin
        alu_start       = 1'b0;
        misc_start      = 1'b0;
        bcd_load_start  = 1'b0;
        bcd_store_start = 1'b0;
        trans_start     = 1'b0;
        c_status        = 1'b1;
        c_status_data   = ((fstat_o | 16'h0041) & ~16'h0200) |
                          (issue_overflow ? 16'h0200 : 16'h0000) |
                          ((issue_underflow && fctrl_o[0] &&
                            issue_is_compare) ? 16'h4500 : 16'h0000);

        if (!fctrl_o[0]) begin
          c_push    = 1'b0;
          c_write   = 1'b0;
          c_swap    = 1'b0;
          c_pop     = 2'd0;
          c_free    = 1'b0;
          c_inc_top = 1'b0;
          c_dec_top = 1'b0;
        end else begin
          // Existing direct result paths retain their destination and stack
          // motion but receive the masked real-indefinite response.
          if (c_push)
            c_push_data = QNAN_INDEF;
          if (issue_underflow && c_write)
            c_write_data = QNAN_INDEF;

          // Deferred operations are short-circuited at issue.  Their exact
          // architectural commit shape is reproduced here, so no wide engine
          // evaluates stale empty-slot bits and no suppressed engine remains
          // busy after an unmasked fault.
          unique case (cmd_op)
            FX_AR_ST0_STI, FX_AR_STI_ST0,
            FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32: begin
              c_write      = 1'b1;
              c_write_idx  = (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
              c_write_data = QNAN_INDEF;
              c_pop        = cmd_pop ? 2'd1 : 2'd0;
            end
            FX_FPREM, FX_FPREM1: begin
              c_write = 1'b1;
              c_write_idx = 3'd0;
              c_write_data = QNAN_INDEF;
              c_status_data[10] = 1'b0;
            end
            FX_FSQRT, FX_FRNDINT, FX_FSCALE,
            FX_F2XM1, FX_FSIN, FX_FCOS: begin
              c_write      = 1'b1;
              c_write_idx  = 3'd0;
              c_write_data = QNAN_INDEF;
            end
            FX_FPATAN, FX_FYL2X, FX_FYL2XP1: begin
              c_write      = 1'b1;
              c_write_idx  = 3'd1;
              c_write_data = QNAN_INDEF;
              c_pop        = 2'd1;
            end
            FX_FSINCOS, FX_FPTAN: begin
              c_write      = 1'b1;
              c_write_idx  = 3'd0;
              c_write_data = QNAN_INDEF;
              c_push       = 1'b1;
              c_push_data  = QNAN_INDEF;
            end
            FX_FBLD: begin
              c_push      = 1'b1;
              c_push_data = QNAN_INDEF;
            end
            FX_FST_M32, FX_FST_M64, FX_FST_M80,
            FX_FIST_M16, FX_FIST_M32, FX_FIST_M64:
              c_pop = cmd_pop ? 2'd1 : 2'd0;
            FX_FBSTP: c_pop = 2'd1;
            default: begin end
          endcase

          // A masked stack underflow materializes the real-indefinite result
          // in its architectural destination.  That destination can itself
          // have been EMPTY (notably DE FADDP/ST(i),ST(0) followed by a pop),
          // so writing its bits alone is insufficient: the state file must
          // clear the EMPTY tag on the same commit.  Keep this after the
          // table, since several deferred forms create c_write there.  The
          // state file applies the write before c_pop; for i==0 a same-edge
          // pop still correctly leaves the popped slot EMPTY.
          if (issue_underflow && c_write)
            c_write_valid = 1'b1;

          // FXCH is unlike the other direct-result forms: it is normally a
          // map-pointer exchange, so neither operand passes through c_write.
          // SDM requires a masked empty operand to become real-indefinite
          // before that exchange.  Tell the state file to materialize only
          // this rare faulting form; normal FXCH retains its compact swap.
          if (issue_underflow && c_swap)
            c_swap_materialize_empty = 1'b1;
        end
      end
    end

    if ((top_state == TOP_ALU) && alu_done) begin
      c_write       = 1'b1;
`ifdef VEN_FP_ARITH_STREAM
      c_write_idx   = arith_owner_dst[2];
`else
      c_write_idx   = pending_dst;
`endif
      c_write_data  = alu_result[79:0];
      c_status      = 1'b1;
      c_status_data = f_arith_fstat(fstat_o, alu_result);
      // Consume only the registered result belonging to this arithmetic
      // owner. Borrowed transcendental micro-operations never enter TOP_ALU.
      c_status_data[9] = alu_rounded_up;
`ifdef VEN_FP_ARITH_STREAM
      c_pop         = arith_owner_pop[2] ? 2'd1 : 2'd0;
`else
      c_pop         = pending_pop ? 2'd1 : 2'd0;
`endif
    end

    if ((top_state == TOP_MEMDIV) && div_special_hit) begin
      c_write       = 1'b1;
      c_write_idx   = pending_dst;
      c_write_data  = div_special_result[79:0];
      c_status      = 1'b1;
      c_status_data = f_arith_fstat(fstat_o, div_special_result);
      c_status_data[9] = 1'b0;
      c_pop         = pending_pop ? 2'd1 : 2'd0;
    end

    if ((top_state == TOP_SRT) && srt_done) begin
      c_write       = 1'b1;
      c_write_idx   = pending_dst;
      c_write_data  = srt_result[79:0];
      c_status      = 1'b1;
      if ((pending_op == FX_FPREM) || (pending_op == FX_FPREM1)) begin
        c_write = !srt_rem_abort;
        c_status_data = (fstat_o & ~16'h4700) |
                        (srt_rem_denormal ? 16'h0002 : 16'h0000) |
                        (srt_result[81] ? 16'h0010 : 16'h0000);
        if (srt_rem_ie)
          c_status_data = c_status_data | 16'h0001;
        else if (srt_rem_c2)
          c_status_data = c_status_data | 16'h0400;
        else begin
          if (srt_rem_q012[2]) c_status_data = c_status_data | 16'h0100;
          if (srt_rem_q012[1]) c_status_data = c_status_data | 16'h4000;
          if (srt_rem_q012[0]) c_status_data = c_status_data | 16'h0200;
        end
        // An operand abort commits no numeric result or quotient. Retain
        // the previous C0/C2/C3, clear C1, and merge only the raised exception.
        // This also matches native x87 for the undefined abort condition bits.
        if (srt_rem_abort)
          c_status_data = (fstat_o & ~16'h0200) |
                          (srt_rem_ie ? 16'h0001 : 16'h0002);
        c_pop = 2'd0;
      end else begin
        c_status_data = f_arith_fstat(fstat_o,
                                      {2'b00, srt_result[82], srt_result[81],
                                       srt_result[80], srt_result[79:0]});
        c_status_data[9] = srt_rounded_up;
        c_pop = pending_pop ? 2'd1 : 2'd0;
      end
    end

    if ((top_state == TOP_MISC) && misc_done) begin
      if (is_misc_store(pending_op)) begin
        c_pop = (pending_pop && !misc_fst_range_block) ? 2'd1 : 2'd0;
      end else begin
        c_write      = !misc_frnd_abort;
        c_write_idx  = 3'd0;
        c_write_data = misc_value;
      end
      if (misc_ie || misc_oe || misc_commit_ue || misc_commit_pe ||
          (pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80, FX_FRNDINT})) begin
        c_status      = 1'b1;
        c_status_data = fstat_o |
                        (misc_ie ? 16'h0001 : 16'h0000) |
                        (misc_frnd_denormal ? 16'h0002 : 16'h0000) |
                        (misc_oe ? 16'h0008 : 16'h0000) |
                        (misc_commit_ue ? 16'h0010 : 16'h0000) |
                        (misc_commit_pe ? 16'h0020 : 16'h0000);
        // Consume only the completing owner: exact FRNDINT also clears
        // stale C1. Invalid/denormal aborts do not round or overwrite ST0.
        if (pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80})
          c_status_data[9] = misc_rounded_up && !misc_fst_range_block;
        if (pending_op == FX_FRNDINT)
          c_status_data[9] = misc_rounded_up && !misc_frnd_abort;
      end
    end

    if ((top_state == TOP_BCD_LOAD) && bcd_load_done) begin
      c_push      = 1'b1;
      c_push_data = bcd_load_result;
      // Valid packed decimal converts exactly, independent of RC/PC.
      // Faulting pushes complete at issue and never reach this owner.
      c_status = 1'b1;
      c_status_data[9] = 1'b0;
    end

    if ((top_state == TOP_BCD_STORE) && bcd_store_done) begin
      c_pop = pending_pop ? 2'd1 : 2'd0;
      if (bcd_store_result[81] || bcd_store_result[80]) begin
        c_status      = 1'b1;
        c_status_data = fstat_o |
                        (bcd_store_result[81] ? 16'h0001 : 16'h0000) |
                        (bcd_store_result[80] ? 16'h0020 : 16'h0000);
      end
    end

    if ((top_state == TOP_TRANS) && trans_done) begin
      if (trans_c2) begin
        c_status      = 1'b1;
        c_status_data = fstat_o | 16'h0400;
      end else if (pending_op != FX_FPTAN) begin
        c_write       = 1'b1;
        c_write_idx   = ((pending_op == FX_FPATAN) ||
                         (pending_op == FX_FYL2X) ||
                         (pending_op == FX_FYL2XP1)) ? 3'd1 : 3'd0;
        c_write_data  = trans_primary;
        if ((pending_op == FX_F2XM1) ||
            (pending_op == FX_FPATAN) ||
            (pending_op == FX_FYL2X) ||
            (pending_op == FX_FYL2XP1)) begin
          if (trans_ie || trans_pe) begin
            c_status      = 1'b1;
            c_status_data = fstat_o |
                            (trans_ie ? 16'h0001 : 16'h0000) |
                            (trans_pe ? 16'h0020 : 16'h0000);
          end
        end else begin
          c_status      = 1'b1;
          c_status_data = (fstat_o & ~16'h0400) |
                          (trans_ie ? 16'h0001 : 16'h0000) |
                          (trans_pe ? 16'h0020 : 16'h0000);
        end
        if (pending_op == FX_FSINCOS) begin
          c_push      = 1'b1;
          c_push_data = trans_secondary;
        end
        if ((pending_op == FX_FPATAN) ||
            (pending_op == FX_FYL2X) ||
            (pending_op == FX_FYL2XP1))
          c_pop = 2'd1;
      end
    end

    if ((top_state == TOP_SRT) && srt_done &&
        (pending_op == FX_FPTAN)) begin
      c_write       = 1'b1;
      c_write_idx   = 3'd0;
      c_write_data  = srt_result[79:0];
      c_push        = 1'b1;
      c_push_data   = 80'h3fff8000000000000000;
      c_status      = 1'b1;
      c_status_data = (fstat_o & ~16'h0400) | 16'h0020;
      c_pop         = 2'd0;
    end
  end

  function automatic logic is_immediate_supported(input fxop_e op);
    unique case (op)
      FX_FNINIT, FX_FNCLEX, FX_FNOP, FX_FWAIT,
      FX_FLDCONST, FX_FLD_STI,
      FX_FLD_M32, FX_FLD_M64, FX_FLD_M80,
      FX_FILD_M16, FX_FILD_M32, FX_FILD_M64,
      FX_FST_STI, FX_FXCH, FX_FFREE, FX_FINCSTP, FX_FDECSTP,
      FX_FABS, FX_FCHS, FX_FLDCW,
      FX_FNSTCW, FX_FNSTSW_M, FX_FNSTSW_AX,
      FX_FNSTENV, FX_FLDENV, FX_FNSAVE, FX_FRSTOR,
      FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64, FX_FUCOM_STI,
      FX_FCOMPP, FX_FUCOMPP, FX_FTST, FX_FXAM,
      FX_FICOM_M16, FX_FICOM_M32: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic has_response_payload(input fxop_e op);
    unique case (op)
      FX_FNSTCW, FX_FNSTSW_M, FX_FNSTSW_AX, FX_FNSTENV, FX_FNSAVE:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // Keep this decision beside the command decode, rather than duplicating an
  // x87-opcode whitelist in the core.  For every asserted case the state-file
  // mutation occurs at the same accept edge, and the registered response is
  // informational only.  A memory image or AX result remains response-owned.
  assign cmd_accept_retire = accept && is_immediate_supported(cmd_op)
                     && !has_response_payload(cmd_op);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      top_state       <= TOP_IDLE;
      pending_dst     <= 3'd0;
      pending_pop     <= 1'b0;
      pending_op      <= FX_NONE;
      alu_commit_retire <= 1'b0;
      rsp_valid       <= 1'b0;
      rsp_unsupported <= 1'b0;
      rsp_stack_fault <= 1'b0;
      rsp_arith       <= '0;
      rsp_store_valid <= 1'b0;
      rsp_store_data  <= 864'd0;
      rsp_store_bytes <= 8'd0;
      rsp_ax_valid    <= 1'b0;
      rsp_ax          <= 16'd0;
      srt_bug_q       <= 1'b0;
      div_mem_q       <= '0;
      div_st0_q       <= '0;
      div_bytes_q     <= '0;
      div_aluop_q     <= '0;
      div_bug_q       <= 1'b0;
`ifndef SYNTHESIS
`ifdef VEN_FP_PERF
      fp_perf_cycles <= 64'd0;
      fp_perf_active <= 1'b0;
      fp_perf_class_q <= FPPC_IMMEDIATE;
      fp_perf_age <= 64'd0;
`ifdef VEN_FP_ARITH_STREAM
      fp_perf_head <= 0;
      fp_perf_tail <= 0;
      fp_perf_count <= 0;
      for (int i=0; i<4; i++) begin
        fp_perf_owner_class[i] <= 0;
        fp_perf_owner_cycle[i] <= 0;
      end
`endif
      fp_perf_fst_m80_plain <= 64'd0;
      fp_perf_fst_m80_pop <= 64'd0;
      fp_perf_fst_m80_stack_fault <= 64'd0;
      for (int i = 0; i < 8; i++) fp_perf_state[i] <= 64'd0;
      for (int i = 0; i < FP_PERF_NCLASS; i++) begin
        fp_perf_accept[i] <= 64'd0;
        fp_perf_latency[i] <= 64'd0;
      end
`endif
`endif
    end else begin
      // The registered ALU's stage-1 valid predicts the next architectural
      // state-file commit one edge ahead.  Register that fact instead of
      // forwarding it combinationally: a core observing this pulse on its
      // next edge retires precisely alongside the existing TOP_ALU c_write.
      // This removes only the adapter's obsolete response-observation bubble;
      // `rsp_valid` remains the complete, registered response contract.
      alu_commit_retire <= (top_state == TOP_ALU) && alu_commit_next;
      rsp_valid       <= 1'b0;
      rsp_unsupported <= 1'b0;
      rsp_stack_fault <= 1'b0;
      rsp_store_valid <= 1'b0;
      rsp_ax_valid    <= 1'b0;
`ifndef SYNTHESIS
`ifdef VEN_FP_PERF
      fp_perf_cycles <= fp_perf_cycles + 64'd1;
      fp_perf_state[int'(top_state)] <= fp_perf_state[int'(top_state)] + 64'd1;
      if (accept && (cmd_op == FX_FST_M80)) begin
        if (issue_stack_fault)
          fp_perf_fst_m80_stack_fault <= fp_perf_fst_m80_stack_fault + 64'd1;
        else if (cmd_pop)
          fp_perf_fst_m80_pop <= fp_perf_fst_m80_pop + 64'd1;
        else
          fp_perf_fst_m80_plain <= fp_perf_fst_m80_plain + 64'd1;
      end
      // Responses are registered, so they observe the command accepted on a
      // preceding edge.  The 11 case keeps the accounting well-defined for a
      // future producer that submits a new command beside an old response.
`ifdef VEN_FP_ARITH_STREAM
      if (accept) begin
        if (fp_perf_count == 4 && !rsp_valid)
          $fatal(1, "FP perf owner overflow");
        fp_perf_accept[fp_perf_class()] <= fp_perf_accept[fp_perf_class()] + 1;
        fp_perf_owner_class[fp_perf_tail] <= fp_perf_class();
        fp_perf_owner_cycle[fp_perf_tail] <= fp_perf_cycles;
        fp_perf_tail <= fp_perf_tail + 1'b1;
      end
      if (rsp_valid) begin
        if (fp_perf_count == 0) $fatal(1, "FP perf response without owner");
        fp_perf_latency[fp_perf_owner_class[fp_perf_head]] <=
            fp_perf_latency[fp_perf_owner_class[fp_perf_head]] +
            (fp_perf_cycles - fp_perf_owner_cycle[fp_perf_head]);
        fp_perf_head <= fp_perf_head + 1'b1;
      end
      case ({accept, rsp_valid})
        2'b10: fp_perf_count <= fp_perf_count + 1'b1;
        2'b01: fp_perf_count <= fp_perf_count - 1'b1;
        default: begin end
      endcase
`else
      unique case ({accept, rsp_valid && fp_perf_active})
        2'b10: begin
          fp_perf_accept[fp_perf_class()] <= fp_perf_accept[fp_perf_class()] + 64'd1;
          fp_perf_class_q <= fp_perf_class();
          fp_perf_age <= 64'd0;
          fp_perf_active <= 1'b1;
        end
        2'b01: begin
          fp_perf_latency[fp_perf_class_q] <= fp_perf_latency[fp_perf_class_q]
                                             + fp_perf_age + 64'd1;
          fp_perf_active <= 1'b0;
        end
        2'b11: begin
          fp_perf_latency[fp_perf_class_q] <= fp_perf_latency[fp_perf_class_q]
                                             + fp_perf_age + 64'd1;
          fp_perf_accept[fp_perf_class()] <= fp_perf_accept[fp_perf_class()] + 64'd1;
          fp_perf_class_q <= fp_perf_class();
          fp_perf_age <= 64'd0;
          fp_perf_active <= 1'b1;
        end
        default: if (fp_perf_active) fp_perf_age <= fp_perf_age + 64'd1;
      endcase
`endif
`endif
`endif

      unique case (top_state)
        TOP_IDLE: begin
          if (accept) begin
            if (issue_stack_fault) begin
              rsp_valid       <= 1'b1;
              rsp_stack_fault <= 1'b1;
              rsp_arith       <= fctrl_o[0] ? {5'd0, QNAN_INDEF} : 85'd0;

              // A masked empty-source store completes with the destination's
              // architectural indefinite.  An unmasked fault emits no store
              // response at all, matching suppression before the memory FSM.
              if (fctrl_o[0]) begin
                unique case (cmd_op)
                  FX_FST_M32: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {832'd0, 32'hffc00000};
                    rsp_store_bytes <= 8'd4;
                  end
                  FX_FST_M64: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {800'd0, 64'hfff8000000000000};
                    rsp_store_bytes <= 8'd8;
                  end
                  FX_FST_M80: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {784'd0, QNAN_INDEF};
                    rsp_store_bytes <= 8'd10;
                  end
                  FX_FIST_M16: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {848'd0, 16'h8000};
                    rsp_store_bytes <= 8'd2;
                  end
                  FX_FIST_M32: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {832'd0, 32'h80000000};
                    rsp_store_bytes <= 8'd4;
                  end
                  FX_FIST_M64: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {800'd0, 64'h8000000000000000};
                    rsp_store_bytes <= 8'd8;
                  end
                  FX_FBSTP: begin
                    rsp_store_valid <= 1'b1;
                    rsp_store_data  <= {784'd0, QNAN_INDEF};
                    rsp_store_bytes <= 8'd10;
                  end
                  default: begin end
                endcase
              end
            end else if ((cmd_op == FX_AR_ST0_STI) ||
                         (cmd_op == FX_AR_STI_ST0) ||
                (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
                (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) begin
              if (is_fast_arith(cmd_aluop)) begin
                pending_dst <= (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
                pending_pop <= cmd_pop;
                pending_op  <= cmd_op;
                top_state   <= TOP_ALU;
              end else if (is_div_arith(cmd_aluop)) begin
                if (mem_arith_cmd) begin
                  div_mem_q   <= cmd_mem;
                  div_st0_q   <= st0_data;
                  div_bytes_q <= cmd_mem_bytes;
                  div_aluop_q <= cmd_aluop;
                  div_bug_q   <= cmd_fdiv_bug;
                  pending_dst <= 3'd0;
                  pending_pop <= cmd_pop;
                  pending_op  <= cmd_op;
                  top_state   <= TOP_MEMDIV;
                end else if (div_special_hit) begin
                  rsp_valid <= 1'b1;
                  rsp_arith <= div_special_result;
                end else begin
                  pending_dst <= (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
                  pending_pop <= cmd_pop;
                  pending_op  <= cmd_op;
                  srt_bug_q   <= cmd_fdiv_bug;
                  top_state   <= TOP_SRT;
                end
              end else begin
                rsp_valid       <= 1'b1;
                rsp_unsupported <= 1'b1;
              end
            end else if (cmd_op == FX_FSQRT) begin
              if (sqrt_special_hit) begin
                rsp_valid <= 1'b1;
                rsp_arith <= sqrt_special_result;
              end else begin
                pending_dst <= 3'd0;
                pending_pop <= 1'b0;
                pending_op  <= cmd_op;
                top_state   <= TOP_SRT;
              end
            end else if ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1)) begin
              pending_dst <= 3'd0;
              pending_pop <= 1'b0;
              pending_op  <= cmd_op;
              top_state   <= TOP_SRT;
            end else if (is_misc_op(cmd_op)) begin
              pending_op  <= cmd_op;
              pending_pop <= cmd_pop;
              top_state   <= TOP_MISC;
            end else if (cmd_op == FX_FBLD) begin
              pending_op  <= cmd_op;
              pending_pop <= 1'b0;
              top_state   <= TOP_BCD_LOAD;
            end else if (cmd_op == FX_FBSTP) begin
              pending_op  <= cmd_op;
              pending_pop <= 1'b1;
              top_state   <= TOP_BCD_STORE;
            end else if (is_trans_op(cmd_op)) begin
              pending_dst <= 3'd0;
              pending_pop <= 1'b0;
              pending_op  <= cmd_op;
              top_state   <= TOP_TRANS;
            end else begin
              rsp_valid <= 1'b1;
              unique case (cmd_op)
                FX_FNSTCW: begin
                  rsp_store_valid <= 1'b1;
                  rsp_store_data  <= {848'd0, fctrl_o};
                  rsp_store_bytes <= 8'd2;
                end
                FX_FNSTSW_M: begin
                  rsp_store_valid <= 1'b1;
                  rsp_store_data  <= {848'd0,
                      (fstat_o & ~16'h3800) | ({13'd0, ftop_o} << 11)};
                  rsp_store_bytes <= 8'd2;
                end
                FX_FNSTSW_AX: begin
                  rsp_ax_valid <= 1'b1;
                  rsp_ax       <= (fstat_o & ~16'h3800) |
                                  ({13'd0, ftop_o} << 11);
                end
                FX_FNSTENV, FX_FNSAVE: begin
                  rsp_store_valid <= 1'b1;
                  rsp_store_data  <= cmd_env16
                                   ? {{112{1'b0}}, env_image16}
                                   : env_image32;
                  rsp_store_bytes <= (cmd_op == FX_FNSAVE)
                                   ? (cmd_env16 ? 8'd94 : 8'd108)
                                   : (cmd_env16 ? 8'd14 : 8'd28);
                end
                default: begin end
              endcase
              if (!is_immediate_supported(cmd_op))
                rsp_unsupported <= 1'b1;
            end
          end
        end

        TOP_ALU: begin
          if (alu_done) begin
            rsp_valid   <= 1'b1;
            rsp_arith   <= alu_result;
`ifdef VEN_FP_ARITH_STREAM
            if (!(arith_owner_valid[0] || arith_owner_valid[1] || alu_start))
`endif
            top_state   <= TOP_IDLE;
          end
        end

        TOP_MEMDIV: begin
          if (div_special_hit) begin
            rsp_valid <= 1'b1;
            rsp_arith <= div_special_result;
            top_state <= TOP_IDLE;
          end else begin
            srt_bug_q <= div_bug_q;
            top_state <= TOP_SRT;
          end
        end

        TOP_SRT: begin
          if (srt_done) begin
            rsp_valid <= 1'b1;
            rsp_arith <= ((pending_op == FX_FPREM) ||
                          (pending_op == FX_FPREM1))
                       ? {3'd0, (srt_result[81] && !srt_rem_abort),
                          1'b0, srt_result[79:0]}
                       : {2'b00, srt_result[82], srt_result[81],
                          srt_result[80], srt_result[79:0]};
            top_state <= TOP_IDLE;
          end
        end

        TOP_MISC: begin
          if (misc_done) begin
            rsp_valid  <= 1'b1;
            rsp_arith  <= {misc_ie, 1'b0, misc_oe, misc_commit_ue, misc_commit_pe,
                           misc_value};
            if (is_misc_store(pending_op)) begin
              rsp_store_valid <= !misc_fst_range_block;
              rsp_store_data  <= {784'd0, misc_value};
              unique case (pending_op)
                FX_FST_M32, FX_FIST_M32: rsp_store_bytes <= 8'd4;
                FX_FST_M64, FX_FIST_M64: rsp_store_bytes <= 8'd8;
                FX_FST_M80:              rsp_store_bytes <= 8'd10;
                default:                 rsp_store_bytes <= 8'd2;
              endcase
            end
            top_state <= TOP_IDLE;
          end
        end

        TOP_BCD_LOAD: begin
          if (bcd_load_done) begin
            rsp_valid  <= 1'b1;
            rsp_arith  <= {5'd0, bcd_load_result};
            top_state  <= TOP_IDLE;
          end
        end

        TOP_BCD_STORE: begin
          if (bcd_store_done) begin
            rsp_valid       <= 1'b1;
            rsp_arith       <= {bcd_store_result[81], 3'd0,
                                bcd_store_result[80],
                                bcd_store_result[79:0]};
            rsp_store_valid <= 1'b1;
            rsp_store_data  <= {784'd0, bcd_store_result[79:0]};
            rsp_store_bytes <= 8'd10;
            top_state       <= TOP_IDLE;
          end
        end

        TOP_TRANS: begin
          if (trans_done) begin
            if ((pending_op == FX_FPTAN) && !trans_c2) begin
              srt_bug_q <= 1'b0;
              top_state <= TOP_SRT;
            end else begin
              rsp_valid <= 1'b1;
              rsp_arith <= {5'd0, trans_primary};
              top_state <= TOP_IDLE;
            end
          end
        end

        default: top_state <= TOP_IDLE;
      endcase
    end
  end

  wire logic _unused_ok = &{1'b0, st0_empty, sti_empty, alu_busy, srt_busy,
                            misc_busy, bcd_load_busy, bcd_store_busy,
                            trans_busy};

`ifndef SYNTHESIS
`ifdef VEN_FP_PERF
  final begin
    $display("[FPPERF] shared-top clocks=%0d", fp_perf_cycles);
    for (int i = 0; i < 8; i++)
      if (fp_perf_state[i] != 0)
        $display("[FPPERF] service-state=%0d clocks=%0d", i, fp_perf_state[i]);
    for (int i = 0; i < FP_PERF_NCLASS; i++)
      if (fp_perf_accept[i] != 0)
        $display("[FPPERF] class=%s commands=%0d response-cycles=%0d avg=%0d.%02d",
                 fp_perf_class_name(3'(i)), fp_perf_accept[i], fp_perf_latency[i],
                 fp_perf_latency[i] / fp_perf_accept[i],
                 ((fp_perf_latency[i] * 100) / fp_perf_accept[i]) % 100);
    if ((fp_perf_fst_m80_plain != 0) || (fp_perf_fst_m80_pop != 0) ||
        (fp_perf_fst_m80_stack_fault != 0))
      $display("[FPPERF] FST m80 census: plain=%0d pop=%0d stack-fault=%0d",
               fp_perf_fst_m80_plain, fp_perf_fst_m80_pop,
               fp_perf_fst_m80_stack_fault);
  end
`endif
`endif

endmodule

`default_nettype wire
