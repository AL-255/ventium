// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_old_ooc.sv -- synthesis-only bundle of the deployed split FP units.
//
// This is not replacement RTL and is never used by the functional tests.  It
// gives Vivado one OOC root that retains the old, independently-instantiated
// transcendental engines, fast arithmetic pipeline, unified SRT engine, BCD
// engines, conversion service, and architectural state file.  The inputs and
// outputs deliberately keep every service observable so synthesis cannot prune
// an engine merely because the normal core dispatcher is outside this bundle.

`default_nettype none

module ven_fp_old_ooc
  import fpu_x87_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst_n,
    input  wire logic [8:0]   start,
    input  wire logic [1:0]   fast_op,
    input  wire fxop_e        misc_op,
    input  wire logic [1:0]   srt_mode,
    input  wire logic         prem1,
    input  wire logic         buggy,
    input  wire logic         fyl_mode,
    input  wire logic [79:0]  operand_a,
    input  wire logic [79:0]  operand_b,
    input  wire logic [1:0]   rc,
    input  wire logic [1:0]   pc,

    // Direct state-file stimulus keeps the old state implementation in the
    // comparison without pulling the integer core or memory FSM into the OOC.
    input  wire logic [17:0]  state_we,
    input  wire logic [2:0]   state_idx,
    input  wire logic [15:0]  state_fctrl,
    input  wire logic [15:0]  state_fstat,
    input  wire logic [31:0]  state_fip,
    input  wire logic [15:0]  state_fcs,
    input  wire logic [31:0]  state_fdp,
    input  wire logic [15:0]  state_fds,
    input  wire logic [2:0]   state_env_top,
    input  wire logic [7:0]   state_env_tag,
    input  wire logic [639:0] state_env_regs,

    output      logic [84:0]  fast_result,
    output      logic [84:0]  misc_result,
    output      logic [82:0]  srt_result,
    output      logic [81:0]  bcd_result,
    output      logic [79:0]  fbld_result,
    output      logic [79:0]  fs_sin,
    output      logic [79:0]  fs_cos,
    output      logic [79:0]  f2_result,
    output      logic [79:0]  fy_result,
    output      logic [79:0]  fa_result,
    output      logic [32:0]  engine_flags,
    output      logic [2:0]   state_top,
    output      logic [15:0]  state_status,
    output      logic [15:0]  state_control,
    output      logic [7:0]   state_tag,
    output      logic [31:0]  state_fip_o,
    output      logic [15:0]  state_fcs_o,
    output      logic [31:0]  state_fdp_o,
    output      logic [15:0]  state_fds_o,
    output      logic [639:0] state_phys_flat,
    output      logic [639:0] state_st_flat
);

  logic fast_vld, fast_pe;
  logic [79:0] fast_y;
  fpu_fx_ppl u_fast (
      .clk(clk), .rst_n(rst_n), .req(start[0]), .op(fast_op),
      .a(operand_a), .b(operand_b), .rc(rc), .pc(pc),
      .vld(fast_vld), .y(fast_y), .pe(fast_pe)
  );
  assign fast_result = {4'd0, fast_pe, fast_y};

  logic srt_busy, srt_done;
  logic [2:0] srt_q;
  logic srt_c2, srt_ie;
  fpu_srt_div u_srt (
      .clk(clk), .rst_n(rst_n), .start(start[1]), .mode(srt_mode),
      .prem1(prem1), .a(operand_a), .b(operand_b),
      .rc(rc), .pc(pc), .buggy(buggy),
      .busy(srt_busy), .done(srt_done), .result(srt_result),
      .rem_q012(srt_q), .rem_c2(srt_c2), .rem_ie(srt_ie)
  );

  logic bcd_busy, bcd_done;
  ven_bcd u_bcd (
      .clk(clk), .rst_n(rst_n), .start(start[2]), .v(operand_a), .rc(rc),
      .busy(bcd_busy), .done(bcd_done), .result(bcd_result)
  );

  logic fbld_busy, fbld_done;
  ven_bcd_to_fp u_fbld (
      .clk(clk), .rst_n(rst_n), .start(start[3]), .bcd(operand_a),
      .busy(fbld_busy), .done(fbld_done), .result(fbld_result)
  );

  logic fs_busy, fs_done, fs_c2;
  fpu_fsincos u_fsincos (
      .clk(clk), .rst_n(rst_n), .start(start[4]), .x(operand_a),
      .busy(fs_busy), .done(fs_done), .sin_o(fs_sin), .cos_o(fs_cos),
      .c2_o(fs_c2)
  );

  logic f2_busy, f2_done, f2_pe, f2_ie;
  fpu_f2xm1 u_f2xm1 (
      .clk(clk), .rst_n(rst_n), .start(start[5]), .x(operand_a), .rc(rc),
      .busy(f2_busy), .done(f2_done), .result(f2_result),
      .inexact(f2_pe), .invalid(f2_ie)
  );

  logic fy_busy, fy_done, fy_pe, fy_ie;
  fpu_fyl2x u_fyl2x (
      .clk(clk), .rst_n(rst_n), .start(start[6]), .mode(fyl_mode),
      .y(operand_b), .x(operand_a), .rc(rc),
      .busy(fy_busy), .done(fy_done),
      .result(fy_result), .inexact(fy_pe), .invalid(fy_ie)
  );

  logic fa_busy, fa_done, fa_pe, fa_ie;
  fpu_fpatan u_fpatan (
      .clk(clk), .rst_n(rst_n), .start(start[7]),
      .y(operand_b), .x(operand_a),
      .rc(rc), .busy(fa_busy), .done(fa_done), .result(fa_result),
      .inexact(fa_pe), .invalid(fa_ie)
  );

  logic misc_busy, misc_done;
  logic [79:0] misc_value;
  logic misc_ie, misc_oe, misc_ue, misc_pe;
  ven_fp_misc u_misc (
      .clk(clk), .rst_n(rst_n), .start(start[8]), .op(misc_op),
      .operand_a(operand_a), .operand_b(operand_b),
      .rc(rc), .pc(pc), .fist_bug(buggy),
      .busy(misc_busy), .done(misc_done), .value(misc_value),
      .flag_ie(misc_ie), .flag_oe(misc_oe),
      .flag_ue(misc_ue), .flag_pe(misc_pe)
  );
  assign misc_result = {misc_ie, 1'b0, misc_oe, misc_ue, misc_pe, misc_value};

  logic [79:0] st0, st1, st2, st3, st4, st5, st6, st7;
  logic [79:0] state_phys_top;
  fpu_top u_state (
      .clk(clk), .rst_n(rst_n),
      .st0(st0), .st1(st1), .st2(st2), .st3(st3),
      .st4(st4), .st5(st5), .st6(st6), .st7(st7),
      .ftop_o(state_top), .fstat_o(state_status),
      .fctrl_o(state_control), .fptag_o(state_tag),
      .rd_phys_top(state_phys_top),
      .we_push(state_we[0]), .push_data(operand_a),
      .we_top(state_we[1]), .top_data(operand_a),
      .we_fstat(state_we[2]), .fstat_wval(state_fstat),
      .we_sti(state_we[3]), .wsti_idx(state_idx), .wsti_data(operand_b),
      .wsti_clr_tag(state_we[3]),
      .we_fxch(state_we[4]), .fxch_idx(state_idx),
      .fxch_a(operand_a), .fxch_b(operand_b),
      .we_pop(state_we[5]), .we_pop2(state_we[6]),
      .we_ffree(state_we[7]), .ffree_idx(state_idx),
      .we_incstp(state_we[8]), .we_decstp(state_we[9]),
      .we_fctrl(state_we[10]), .fctrl_wval(state_fctrl),
      .we_fninit(state_we[11]),
      .we_eptr(state_we[12]), .eptr_fip(state_fip), .eptr_fcs(state_fcs),
      .we_dptr(state_we[13]), .dptr_fdp(state_fdp), .dptr_fds(state_fds),
      .fip_o(state_fip_o), .fcs_o(state_fcs_o),
      .fdp_o(state_fdp_o), .fds_o(state_fds_o),
      .fpr_flat_o(state_phys_flat),
      .we_envld(state_we[14]), .env_fctrl(state_fctrl),
      .env_ftop(state_env_top), .env_fstat(state_fstat),
      .env_fptag(state_env_tag),
      .we_envregs(state_we[15]), .env_fpr_flat(state_env_regs),
      .we_wabs(state_we[16]), .wabs_idx(state_idx), .wabs_data(operand_a),
      .we_wabs_fstat(state_we[17]), .wabs_fstat(state_fstat)
  );

  assign state_st_flat = {st7, st6, st5, st4, st3, st2, st1, st0};
  assign engine_flags = {
      misc_ie, misc_oe, misc_ue, misc_pe, misc_done, misc_busy,
      fa_ie, fa_pe, fa_done, fa_busy, fy_ie, fy_pe, fy_done, fy_busy,
      f2_ie, f2_pe, f2_done, f2_busy, fs_c2, fs_done, fs_busy,
      srt_ie, srt_c2, srt_q, srt_done, srt_busy, fbld_done, fbld_busy,
      bcd_done, bcd_busy, fast_vld
  };

  wire logic _unused_ok = state_phys_top[0];

endmodule

`default_nettype wire
