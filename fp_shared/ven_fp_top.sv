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

    input  wire logic         cmd_valid,
    output      logic         cmd_ready,
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
    TOP_TRANS
  } top_state_t;
  top_state_t top_state;

  logic [79:0] st0_data, sti_data;
  logic st0_empty, sti_empty;
  logic [2:0] state_rd1_idx;

  // State commit wires.
  logic        c_init, c_push, c_write, c_swap, c_free;
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
  logic        alu_start, alu_busy, alu_done;
  logic [2:0]  alu_subop;
  logic [79:0] alu_a, alu_b;
  logic [84:0] alu_result;
  logic [2:0]  pending_dst;
  logic        pending_pop;
  fxop_e        pending_op;

  // One registered service for all rare narrow-store and conversion work.
  logic        misc_start, misc_busy, misc_done;
  logic [79:0] misc_value;
  logic        misc_ie, misc_oe, misc_ue, misc_pe;

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
  logic [2:0]  srt_rem_q012;
  logic        srt_rem_c2, srt_rem_ie;

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
  logic [639:0] env_load_regs_phys;
  logic issue_reads_st0, issue_reads_sti, issue_push, issue_pop2;
  logic issue_is_compare, issue_overflow, issue_underflow, issue_stack_fault;

  localparam logic [79:0] QNAN_INDEF = 80'hffffc000000000000000;

  wire logic accept = cmd_valid & cmd_ready;

  assign cmd_ready = (top_state == TOP_IDLE);
  assign busy      = (top_state != TOP_IDLE);

  ven_fp_state u_state (
      .clk(clk),
      .rst_n(rst_n),
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
      .eptr_fip(cmd_fip),
      .eptr_fcs(cmd_fcs),
      .commit_dptr(c_dptr),
      .dptr_fdp(cmd_fdp),
      .dptr_fds(cmd_fds),
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
      .result(alu_result)
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
      .flag_pe(misc_pe)
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
      .a(srt_a),
      .b(srt_b),
      .rc(srt_rc),
      .pc(srt_pc),
      .buggy(srt_bug_q),
      .busy(srt_busy),
      .done(srt_done),
      .result(srt_result),
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
      FX_FST_STI:
        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end
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
    alu_a = st0_data;
    alu_b = sti_data;
    unique case (cmd_op)
      FX_AR_STI_ST0: begin
        alu_a = sti_data;
        alu_b = st0_data;
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
                           fcom_ie(st0_data, cmp_b, cmp_signaling));
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
        {16'd0, fds_o},
        fdp_o,
        {5'd0, 11'd0, fcs_o},
        fip_o,
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
    div_special_raw    = f_special(cmd_aluop, alu_a, alu_b);
    div_special_hit    = 1'b0;
    div_special_result = '0;
    if (div_special_raw[81]) begin
      div_special_hit    = 1'b1;
      div_special_result = {div_special_raw[80], 4'b0000,
                            div_special_raw[79:0]};
    end else if (f_zero_over_zero(cmd_aluop, alu_a, alu_b)) begin
      div_special_hit    = 1'b1;
      div_special_result = {1'b1, 4'b0000,
                            80'hffffc000000000000000};
    end else if (f_div_by_zero(cmd_aluop, alu_a, alu_b)) begin
      div_special_hit    = 1'b1;
      div_special_result = {1'b0, 1'b1, 3'b000,
                            fx_make(alu_a[79] ^ alu_b[79], 15'h7fff,
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

  always_comb begin
    srt_start = 1'b0;
    srt_mode  = 2'd0;
    srt_rc    = fctrl_o[11:10];
    srt_pc    = fctrl_o[9:8];
    srt_a     = (cmd_aluop == 3'd7) ? alu_b : alu_a;
    srt_b     = (cmd_aluop == 3'd7) ? alu_a : alu_b;
    if (accept && !issue_stack_fault &&
        ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0) ||
         (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64) ||
         (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)) &&
        is_div_arith(cmd_aluop) && !div_special_hit) begin
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
      srt_rc    = trans_divide_rc;
      srt_pc    = 2'b11;
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
          else if (is_div_arith(cmd_aluop) && div_special_hit) begin
            c_write       = 1'b1;
            c_write_idx   = (cmd_op == FX_AR_STI_ST0) ? cmd_sti : 3'd0;
            c_write_data  = div_special_result[79:0];
            c_status      = 1'b1;
            c_status_data = f_arith_fstat(fstat_o, div_special_result);
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
          end
        end
        default: begin end
      endcase

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
            FX_FSQRT, FX_FRNDINT, FX_FSCALE, FX_FPREM, FX_FPREM1,
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
        end
      end
    end

    if ((top_state == TOP_ALU) && alu_done) begin
      c_write       = 1'b1;
      c_write_idx   = pending_dst;
      c_write_data  = alu_result[79:0];
      c_status      = 1'b1;
      c_status_data = f_arith_fstat(fstat_o, alu_result);
      c_pop         = pending_pop ? 2'd1 : 2'd0;
    end

    if ((top_state == TOP_SRT) && srt_done) begin
      c_write       = 1'b1;
      c_write_idx   = pending_dst;
      c_write_data  = srt_result[79:0];
      c_status      = 1'b1;
      if ((pending_op == FX_FPREM) || (pending_op == FX_FPREM1)) begin
        c_status_data = fstat_o & ~16'h4700;
        if (srt_rem_ie)
          c_status_data = c_status_data | 16'h0001;
        else if (srt_rem_c2)
          c_status_data = c_status_data | 16'h0400;
        else begin
          if (srt_rem_q012[2]) c_status_data = c_status_data | 16'h0100;
          if (srt_rem_q012[1]) c_status_data = c_status_data | 16'h4000;
          if (srt_rem_q012[0]) c_status_data = c_status_data | 16'h0200;
        end
        c_pop = 2'd0;
      end else begin
        c_status_data = f_arith_fstat(fstat_o,
                                      {2'b00, srt_result[82], srt_result[81],
                                       srt_result[80], srt_result[79:0]});
        c_pop = pending_pop ? 2'd1 : 2'd0;
      end
    end

    if ((top_state == TOP_MISC) && misc_done) begin
      if (is_misc_store(pending_op)) begin
        c_pop = pending_pop ? 2'd1 : 2'd0;
      end else begin
        c_write      = 1'b1;
        c_write_idx  = 3'd0;
        c_write_data = misc_value;
      end
      if (misc_ie || misc_oe || misc_ue || misc_pe) begin
        c_status      = 1'b1;
        c_status_data = fstat_o |
                        (misc_ie ? 16'h0001 : 16'h0000) |
                        (misc_oe ? 16'h0008 : 16'h0000) |
                        (misc_ue ? 16'h0010 : 16'h0000) |
                        (misc_pe ? 16'h0020 : 16'h0000);
      end
    end

    if ((top_state == TOP_BCD_LOAD) && bcd_load_done) begin
      c_push      = 1'b1;
      c_push_data = bcd_load_result;
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

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      top_state       <= TOP_IDLE;
      pending_dst     <= 3'd0;
      pending_pop     <= 1'b0;
      pending_op      <= FX_NONE;
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
    end else begin
      rsp_valid       <= 1'b0;
      rsp_unsupported <= 1'b0;
      rsp_stack_fault <= 1'b0;
      rsp_store_valid <= 1'b0;
      rsp_ax_valid    <= 1'b0;

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
                if (div_special_hit) begin
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
            top_state   <= TOP_IDLE;
          end
        end

        TOP_SRT: begin
          if (srt_done) begin
            rsp_valid <= 1'b1;
            rsp_arith <= ((pending_op == FX_FPREM) ||
                          (pending_op == FX_FPREM1))
                       ? {5'd0, srt_result[79:0]}
                       : {2'b00, srt_result[82], srt_result[81],
                          srt_result[80], srt_result[79:0]};
            top_state <= TOP_IDLE;
          end
        end

        TOP_MISC: begin
          if (misc_done) begin
            rsp_valid  <= 1'b1;
            rsp_arith  <= {misc_ie, 1'b0, misc_oe, misc_ue, misc_pe,
                           misc_value};
            if (is_misc_store(pending_op)) begin
              rsp_store_valid <= 1'b1;
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

endmodule

`default_nettype wire
