// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_trans.sv -- shared, sequenced x87 transcendental service.
//
// The service borrows the parent's one floatx80 add/multiply pipeline.  Every
// polynomial and reduction step is serialized through that datapath; no
// opcode-specific ALU is instantiated.  The parent also owns the single SRT
// divider used for FPTAN's final sine/cosine quotient.

`default_nettype none

module ven_fp_trans
  import fpu_x87_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire fxop_e       op,
    input  wire logic [79:0] x,
    input  wire logic [79:0] y,
    input  wire logic [1:0]  rc,
    output      logic        fx_req,
    output      logic [1:0]  fx_op,
    output      logic [79:0] fx_a,
    output      logic [79:0] fx_b,
    output      logic [1:0]  fx_rc,
    output      logic [1:0]  fx_pc,
    input  wire logic        fx_vld,
    input  wire logic [79:0] fx_result,
    input  wire logic        fx_pe,
    output      logic        divide_start,
    output      logic [79:0] divide_a,
    output      logic [79:0] divide_b,
    output      logic [1:0]  divide_rc,
    input  wire logic        divide_done,
    input  wire logic [79:0] divide_result,
    output      logic        busy,
    output      logic        done,
    output      logic [79:0] primary,
    output      logic [79:0] secondary,
    output      logic        flag_c2,
    output      logic        flag_ie,
    output      logic        flag_pe
);

  `include "fpu_fsincos_rom.svh"
  `include "fpu_f2xm1_rom.svh"
  `include "fpu_fpatan_rom.svh"
  `include "fpu_fyl2x_rom.svh"

  localparam logic [1:0] FXP_ADD = 2'd0;
  localparam logic [1:0] FXP_MUL = 2'd1;
  localparam logic [1:0] FXP_SUB = 2'd2;
  localparam int NT = 11;

  typedef enum logic [5:0] {
    T_IDLE, T_TRIG_REDUCE_MUL, T_TRIG_PIO2_MUL, T_TRIG_PIO2_SUB,
    T_TRIG_R2, T_TRIG_SIN_MUL, T_TRIG_SIN_ADD,
    T_TRIG_COS_MUL, T_TRIG_COS_ADD, T_TRIG_SIN_FINISH,
    T_TRIG_QUADRANT,
    T_F2_SETUP, T_F2_TABLE_WAIT, T_F2_TABLE_SUB, T_F2_HORNER,
    T_F2_RECONSTRUCT, T_F2_RECONSTRUCT_TABLE, T_F2_PACK,
    T_FY_CLASS, T_FY_SCALE_SUB, T_FY_SPECIAL_MUL,
    T_FY_TINY_MUL1, T_FY_TINY_MUL2, T_FY_CDIV,
    T_FY_CT2, T_FY_HORNER, T_FY_RECONSTRUCT,
    T_FY_POST_COMBINE, T_FY_POST_MUL, T_FY_PACK,
    T_ATAN_CLASS, T_ATAN_X_SETUP, T_ATAN_SPLIT, T_ATAN_SPLIT_Y,
    T_ATAN_Z_SETUP, T_ATAN_Z2, T_ATAN_HORNER,
    T_ATAN_RECONSTRUCT, T_ATAN_ATANX, T_ATAN_ADJUST,
    T_ATAN_PACK, T_ATAN_FAR_REQ, T_ATAN_FAR_WAIT,
    T_QDIV_A, T_QDIV_B, T_QDIV_C, T_QDIV_D,
    T_WIDE_RESULT,
    T_DONE
  } trans_state_t;
  trans_state_t state;

  typedef enum logic [2:0] {
    QDIV_FY, QDIV_ATAN_X, QDIV_ATAN_Z
  } qdiv_cont_t;
  qdiv_cont_t qdiv_cont_q;

  typedef enum logic [3:0] {
    WIDE_QDIV, WIDE_FY_TINY1, WIDE_FY_TINY2,
    WIDE_FY_T2, WIDE_FY_RECON, WIDE_FY_POST,
    WIDE_ATAN_TX, WIDE_ATAN_Z2, WIDE_ATAN_RECON,
    WIDE_F2_TINY, WIDE_F2_RECON, WIDE_F2_TABLE
  } wide_cont_t;
  wide_cont_t wide_cont_q;

  fxop_e op_q;
  logic [79:0] x_q, y_q, r_q, r2_q, n_float_q;
  logic [79:0] sin_poly_q, cos_poly_q, tmp_q;
  logic [1:0] rc_q, quadrant_q;
  logic [3:0] reduce_step_q, poly_step_q;
  logic issued_q;

  // F2XM1 working set.  The three reduction tables infer synchronous ROMs;
  // the polynomial itself uses u_shared_fx one operation at a time.
  logic [79:0] f2_y_q, f2_accum_q;
  logic [6:0]  f2_index_q;
  logic [3:0]  f2_step_q;
  logic        f2_sign_q;
  logic signed [31:0] f2_exp_q;
  logic [63:0] f2_sig0_q, f2_sig1_q;
  (* rom_style = "block" *) logic [79:0] f2_t_mem  [0:64];
  (* rom_style = "block" *) logic [79:0] f2_e2_mem [0:64];
  (* rom_style = "block" *) logic [79:0] f2_em_mem [0:64];
  logic [79:0] f2_t_rd, f2_e2_rd, f2_em_rd;

  // FYL2X/FYL2XP1 working set.  Both opcodes use this one register set, the
  // same floating add/multiply pipeline as the trig/F2 paths, and the common
  // quotient and wide-multiply services below.
  logic        fy_mode_q, fy_arg_sign_q, fy_y_sign_q, fy_result_sign_q;
  logic signed [31:0] fy_arg_exp_q, fy_y_exp_q, fy_int_exp_q;
  logic signed [31:0] fy_t_exp_q, fy_result_exp_q;
  logic [63:0] fy_arg_sig_q, fy_y_sig_q;
  logic [63:0] fy_t_sig0_q, fy_t_sig1_q;
  logic [63:0] fy_result_sig0_q, fy_result_sig1_q;
  logic [79:0] fy_scaled_q, fy_t2_q, fy_accum_q;
  logic [4:0]  fy_step_q;

  // FPATAN working set.  The two rational divisions reuse T_QDIV_*, while
  // z^2 and polynomial reconstruction reuse the one wide multiplier.
  logic at_result_sign_q, at_adjust_sub_q, at_y_sign_q, at_z_sign_q;
  logic signed [31:0] at_num_exp_q, at_den_exp_q, at_x_exp_q;
  logic signed [31:0] at_t_exp_q, at_y_exp_q, at_z_exp_q;
  logic signed [31:0] at_adjust_exp_q, at_atanz_exp_q;
  logic signed [31:0] at_atanx_exp_q, at_result_exp_q;
  logic [63:0] at_num_sig_q, at_den_sig_q, at_t_sig_q;
  logic [63:0] at_x_sig0_q, at_x_sig1_q;
  logic [63:0] at_y_sig0_q, at_y_sig1_q;
  logic [63:0] at_z_sig0_q, at_z_sig1_q;
  logic [63:0] at_adjust_sig0_q, at_adjust_sig1_q;
  logic [63:0] at_atanz_sig0_q, at_atanz_sig1_q;
  logic [63:0] at_atanx_sig0_q, at_atanx_sig1_q;
  logic [63:0] at_result_sig0_q, at_result_sig1_q;
  logic [3:0] at_table_index_q, at_step_q;
  logic [79:0] at_z2_q, at_accum_q;

  // Shared quotient micro-engine: one sequential estimateDiv instance serves
  // FYL2X and both FPATAN rational reductions.  The correction loop advances
  // one 192-bit add per clock rather than forming a chained setup path.
  logic [63:0] q_dsig0_q, q_dsig1_q;
  logic [63:0] q_rsig0_q, q_rsig1_q, q_rsig2_q, q_sig0_q;
  logic signed [31:0] q_exp_q;
  logic [2:0] q_correction_q;
  logic ed_req, ed_vld, ed_issued_q;
  logic [63:0] ed_a0, ed_a1, ed_z;

  ven_fp_estdiv u_shared_estdiv (
      .clk(clk), .rst_n(rst_n), .req(ed_req),
      .a0(ed_a0), .a1(ed_a1), .b(q_dsig0_q),
      .vld(ed_vld), .z(ed_z)
  );

  // One iterative 128x128 wide-integer service, explicitly time-multiplexed
  // across every quotient, reconstruction, and post-scale multiplication.
  // Internally it contains exactly one 32x32 limb multiplier.
  logic [63:0] wide_a0_q, wide_a1_q, wide_b0_q, wide_b1_q;
  logic wide_start, wide_busy, wide_done, wide_issued_q;
  logic [255:0] wide_product;

  ven_fp_widemul u_shared_widemul (
      .clk(clk), .rst_n(rst_n), .start(wide_start),
      .a({wide_a0_q, wide_a1_q}), .b({wide_b0_q, wide_b1_q}),
      .busy(wide_busy), .done(wide_done), .product(wide_product)
  );

  initial begin
    for (int i = 0; i <= 64; i++) begin
      f2_t_mem[i]  = F2_T[i];
      f2_e2_mem[i] = F2_E2[i];
      f2_em_mem[i] = F2_EM[i];
    end
  end

  always_ff @(posedge clk) begin
    f2_t_rd  <= f2_t_mem[f2_index_q];
    f2_e2_rd <= f2_e2_mem[f2_index_q];
    f2_em_rd <= f2_em_mem[f2_index_q];
  end

  function automatic logic [79:0] sin_coeff(input logic [3:0] k);
    unique case (k)
      4'd0: sin_coeff=T_SIN0; 4'd1: sin_coeff=T_SIN1;
      4'd2: sin_coeff=T_SIN2; 4'd3: sin_coeff=T_SIN3;
      4'd4: sin_coeff=T_SIN4; 4'd5: sin_coeff=T_SIN5;
      4'd6: sin_coeff=T_SIN6; 4'd7: sin_coeff=T_SIN7;
      4'd8: sin_coeff=T_SIN8; 4'd9: sin_coeff=T_SIN9;
      default: sin_coeff=T_SIN10;
    endcase
  endfunction

  function automatic logic [79:0] cos_coeff(input logic [3:0] k);
    unique case (k)
      4'd0: cos_coeff=T_COS0; 4'd1: cos_coeff=T_COS1;
      4'd2: cos_coeff=T_COS2; 4'd3: cos_coeff=T_COS3;
      4'd4: cos_coeff=T_COS4; 4'd5: cos_coeff=T_COS5;
      4'd6: cos_coeff=T_COS6; 4'd7: cos_coeff=T_COS7;
      4'd8: cos_coeff=T_COS8; 4'd9: cos_coeff=T_COS9;
      default: cos_coeff=T_COS10;
    endcase
  endfunction

  function automatic logic [79:0] negate(input logic [79:0] value);
    return {~value[79], value[78:0]};
  endfunction

  function automatic logic is_trig(input fxop_e value);
    return (value == FX_FSIN) || (value == FX_FCOS) ||
           (value == FX_FSINCOS) || (value == FX_FPTAN);
  endfunction

  function automatic int clz64(input logic [63:0] value);
    clz64 = 64;
    for (int i = 63; i >= 0; i--)
      if (value[i]) begin clz64 = 63-i; break; end
  endfunction

  function automatic int clz32(input logic [31:0] value);
    clz32 = 32;
    for (int i = 31; i >= 0; i--)
      if (value[i]) begin clz32 = 31-i; break; end
  endfunction

  function automatic logic [127:0] shift128_right_jam(
      input logic [63:0] high, input logic [63:0] low, input int count);
    logic [63:0] result_high, result_low;
    int neg_count;
    begin
      neg_count = (-count) & 63;
      if (count == 0) begin
        result_high = high;
        result_low  = low;
      end else if (count < 64) begin
        result_high = high >> count;
        result_low  = (high << neg_count) | (low >> count) |
                      (((low << neg_count) != 64'd0) ? 64'd1 : 64'd0);
      end else begin
        result_high = 64'd0;
        if (count == 64)
          result_low = high | ((low != 64'd0) ? 64'd1 : 64'd0);
        else if (count < 128)
          result_low = (high >> (count & 63)) |
                       ((((high << neg_count) | low) != 64'd0) ? 64'd1 : 64'd0);
        else
          result_low = ((high | low) != 64'd0) ? 64'd1 : 64'd0;
      end
      return {result_high, result_low};
    end
  endfunction

  function automatic logic [127:0] shift128_right(
      input logic [63:0] high, input logic [63:0] low, input int count);
    logic [63:0] result_high, result_low;
    int neg_count;
    begin
      neg_count = (-count) & 63;
      if (count == 0) begin
        result_high = high;
        result_low  = low;
      end else if (count < 64) begin
        result_high = high >> count;
        result_low  = (high << neg_count) | (low >> count);
      end else begin
        result_high = 64'd0;
        result_low  = (count < 128) ? (high >> (count & 63)) : 64'd0;
      end
      return {result_high, result_low};
    end
  endfunction

  function automatic logic [127:0] shift128_left(
      input logic [63:0] high, input logic [63:0] low, input int count);
    logic [63:0] result_high, result_low;
    begin
      if (count < 64) begin
        result_low  = low << count;
        result_high = (count == 0) ? high
                    : ((high << count) | (low >> ((-count) & 63)));
      end else begin
        result_low  = 64'd0;
        result_high = low << (count - 64);
      end
      return {result_high, result_low};
    end
  endfunction

  function automatic logic [79:0] normalize_round_pack(
      input logic sign, input logic signed [31:0] exponent_in,
      input logic [63:0] sig_high_in, input logic [63:0] sig_low_in,
      input logic [1:0] rounding);
    logic [63:0] sig_high, sig_low;
    logic signed [31:0] exponent;
    logic increment, nearest;
    int shift;
    begin
      sig_high = sig_high_in;
      sig_low  = sig_low_in;
      exponent = exponent_in;
      if (sig_high == 64'd0) begin
        sig_high = sig_low;
        sig_low  = 64'd0;
        exponent = exponent - 32'sd64;
      end
      shift = clz64(sig_high);
      if ((shift != 0) && (shift < 64)) begin
        sig_high = (sig_high << shift) | (sig_low >> (64-shift));
        sig_low  = sig_low << shift;
      end
      exponent = exponent - shift;
      nearest = (rounding == 2'd0);
      unique case (rounding)
        2'd0: increment = sig_low[63];
        2'd1: increment = sign && (sig_low != 64'd0);
        2'd2: increment = !sign && (sig_low != 64'd0);
        default: increment = 1'b0;
      endcase
      if (increment) begin
        sig_high = sig_high + 64'd1;
        if (sig_high == 64'd0) begin
          exponent = exponent + 32'sd1;
          sig_high = 64'h8000000000000000;
        end else if (((sig_low << 1) == 64'd0) && nearest)
          sig_high = sig_high & ~64'd1;
      end else if (sig_high == 64'd0)
        exponent = 32'sd0;
      return {sign, exponent[14:0], sig_high};
    end
  endfunction

  function automatic logic [79:0] f2_coefficient(input logic [3:0] step);
    unique case (step)
      4'd1: f2_coefficient=F2_C6;
      4'd3: f2_coefficient=F2_C5;
      4'd5: f2_coefficient=F2_C4;
      4'd7: f2_coefficient=F2_C3;
      4'd9: f2_coefficient=F2_C2;
      4'd11:f2_coefficient=F2_C1;
      default: f2_coefficient=F2_C0_LOW;
    endcase
  endfunction

  function automatic logic [79:0] fy_coefficient(input logic [4:0] step);
    unique case (step)
      5'd1:  fy_coefficient=FY_C8;
      5'd3:  fy_coefficient=FY_C7;
      5'd5:  fy_coefficient=FY_C6;
      5'd7:  fy_coefficient=FY_C5;
      5'd9:  fy_coefficient=FY_C4;
      5'd11: fy_coefficient=FY_C3;
      5'd13: fy_coefficient=FY_C2;
      5'd15: fy_coefficient=FY_C1;
      default: fy_coefficient=FY_C0_LOW;
    endcase
  endfunction

  function automatic logic [79:0] atan_coefficient(input logic [3:0] step);
    unique case (step)
      4'd1: atan_coefficient=FA_C5;
      4'd3: atan_coefficient=FA_C4;
      4'd5: atan_coefficient=FA_C3;
      4'd7: atan_coefficient=FA_C2;
      default: atan_coefficient=FA_C1;
    endcase
  endfunction

  wire logic [3:0] coeff_index = 4'(NT-1) - poly_step_q;
  wire logic [79:0] pio2_piece = (reduce_step_q == 4'd1) ? T_PIO2_1 :
                                  (reduce_step_q == 4'd2) ? T_PIO2_2 :
                                                                    T_PIO2_3;
  wire logic trig_out_of_range = x_q[78:64] >= 15'h403e;

  assign busy = (state != T_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= T_IDLE;
      done      <= 1'b0;
      fx_req    <= 1'b0;
      ed_req    <= 1'b0;
      wide_start <= 1'b0;
      wide_issued_q <= 1'b0;
      fx_rc     <= 2'd0;
      fx_pc     <= 2'b11;
      divide_start <= 1'b0;
      divide_a     <= 80'd0;
      divide_b     <= 80'd0;
      divide_rc    <= 2'd0;
      issued_q  <= 1'b0;
      ed_issued_q <= 1'b0;
      primary   <= 80'd0;
      secondary <= 80'd0;
      flag_c2   <= 1'b0;
      flag_ie   <= 1'b0;
      flag_pe   <= 1'b0;
    end else begin
      done   <= 1'b0;
      fx_req <= 1'b0;
      ed_req <= 1'b0;
      wide_start <= 1'b0;
      divide_start <= 1'b0;

      unique case (state)
        T_IDLE: begin
          if (start) begin
            op_q      <= op;
            x_q       <= x;
            y_q       <= y;
            fy_mode_q <= (op == FX_FYL2XP1);
            rc_q      <= rc;
            flag_c2   <= 1'b0;
            flag_ie   <= 1'b0;
            flag_pe   <= 1'b0;
            issued_q  <= 1'b0;
            ed_issued_q <= 1'b0;
            fx_rc     <= 2'd0;
            fx_pc     <= 2'b11;
            if (is_trig(op))
              state <= T_TRIG_REDUCE_MUL;
            else if (op == FX_F2XM1)
              state <= T_F2_SETUP;
            else if ((op == FX_FYL2X) || (op == FX_FYL2XP1))
              state <= T_FY_CLASS;
            else if (op == FX_FPATAN)
              state <= T_ATAN_CLASS;
            else begin
              primary <= 80'hffffc000000000000000;
              flag_ie <= 1'b1;
              state   <= T_DONE;
            end
          end
        end

        // n = round(x * 2/pi), followed by three-piece Cody-Waite reduction.
        T_TRIG_REDUCE_MUL: begin
          if (trig_out_of_range) begin
            primary   <= x_q;
            secondary <= x_q;
            flag_c2   <= 1'b1;
            state     <= T_DONE;
          end else if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= x_q;
            fx_b     <= T_2OPI;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            logic signed [63:0] n;
            n = (fx_result[78:64] < 15'h3ffe) ? 64'sd0
                                               : fx_to_int(fx_result);
            quadrant_q   <= n[1:0];
            n_float_q    <= fx_from_int(n, 2'b11);
            r_q          <= x_q;
            reduce_step_q<= 4'd1;
            issued_q     <= 1'b0;
            state        <= T_TRIG_PIO2_MUL;
          end
        end

        T_TRIG_PIO2_MUL: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= n_float_q;
            fx_b     <= pio2_piece;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            tmp_q    <= fx_result;
            issued_q <= 1'b0;
            state    <= T_TRIG_PIO2_SUB;
          end
        end

        T_TRIG_PIO2_SUB: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_SUB;
            fx_a     <= r_q;
            fx_b     <= tmp_q;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            r_q      <= fx_result;
            issued_q <= 1'b0;
            if (reduce_step_q == 4'd3) begin
              poly_step_q <= 4'd0;
              state       <= T_TRIG_R2;
            end else begin
              reduce_step_q <= reduce_step_q + 4'd1;
              state         <= T_TRIG_PIO2_MUL;
            end
          end
        end

        T_TRIG_R2: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= r_q;
            fx_b     <= r_q;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            r2_q       <= fx_result;
            sin_poly_q <= sin_coeff(4'(NT-1));
            cos_poly_q <= cos_coeff(4'(NT-1));
            poly_step_q<= 4'd1;
            issued_q   <= 1'b0;
            state      <= T_TRIG_SIN_MUL;
          end
        end

        T_TRIG_SIN_MUL: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= sin_poly_q;
            fx_b     <= r2_q;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            tmp_q    <= fx_result;
            issued_q <= 1'b0;
            state    <= T_TRIG_SIN_ADD;
          end
        end

        T_TRIG_SIN_ADD: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_ADD;
            fx_a     <= tmp_q;
            fx_b     <= sin_coeff(coeff_index);
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            sin_poly_q <= fx_result;
            issued_q   <= 1'b0;
            state      <= T_TRIG_COS_MUL;
          end
        end

        T_TRIG_COS_MUL: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= cos_poly_q;
            fx_b     <= r2_q;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            tmp_q    <= fx_result;
            issued_q <= 1'b0;
            state    <= T_TRIG_COS_ADD;
          end
        end

        T_TRIG_COS_ADD: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_ADD;
            fx_a     <= tmp_q;
            fx_b     <= cos_coeff(coeff_index);
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            cos_poly_q <= fx_result;
            issued_q   <= 1'b0;
            if (poly_step_q == 4'(NT-1))
              state <= T_TRIG_SIN_FINISH;
            else begin
              poly_step_q <= poly_step_q + 4'd1;
              state       <= T_TRIG_SIN_MUL;
            end
          end
        end

        T_TRIG_SIN_FINISH: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_MUL;
            fx_a     <= sin_poly_q;
            fx_b     <= r_q;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            sin_poly_q <= fx_result;
            issued_q   <= 1'b0;
            state      <= T_TRIG_QUADRANT;
          end
        end

        T_TRIG_QUADRANT: begin
          logic [79:0] sin_value, cos_value;
          unique case (quadrant_q)
            2'd0: begin sin_value=sin_poly_q;         cos_value=cos_poly_q; end
            2'd1: begin sin_value=cos_poly_q;         cos_value=negate(sin_poly_q); end
            2'd2: begin sin_value=negate(sin_poly_q); cos_value=negate(cos_poly_q); end
            default: begin sin_value=negate(cos_poly_q); cos_value=sin_poly_q; end
          endcase
          primary   <= (op_q == FX_FCOS) ? cos_value : sin_value;
          secondary <= cos_value;
          flag_pe   <= 1'b1;
          state     <= T_DONE;
        end

        T_F2_SETUP: begin
          flag_pe <= 1'b1;
          flag_ie <= 1'b0;
          if ((x_q[78:64] > 15'h3fff) ||
              ((x_q[78:64] == 15'h3fff) &&
               (x_q[63:0] != 64'h8000000000000000))) begin
            primary <= 80'hffffc000000000000000;
            flag_pe <= 1'b0;
            flag_ie <= 1'b1;
            state   <= T_DONE;
          end else if (x_q[78:64] == 15'h3fff) begin
            primary <= x_q[79] ? 80'hbffe8000000000000000 : x_q;
            flag_pe <= 1'b0;
            state   <= T_DONE;
          end else if (x_q[78:64] < 15'h3fb0) begin
            if (fx_is_zero(x_q)) begin
              primary <= x_q;
              flag_pe <= 1'b0;
              state   <= T_DONE;
            end else begin
              wide_a0_q <= F2_LN2_HI;
              wide_a1_q <= F2_LN2_LO;
              wide_b0_q <= x_q[63:0];
              wide_b1_q <= 64'd0;
              wide_cont_q <= WIDE_F2_TINY;
              f2_exp_q  <= $signed({17'd0, x_q[78:64]});
              f2_sign_q <= x_q[79];
              state     <= T_WIDE_RESULT;
            end
          end else begin
            logic [79:0] scaled;
            logic signed [63:0] rounded;
            scaled = {x_q[79], x_q[78:64] + 15'd5, x_q[63:0]};
            rounded = ((x_q[78:64] + 15'd5) < 15'h3ffe)
                    ? 64'sd0 : fx_to_int(scaled);
            f2_index_q <= 7'(32 + rounded);
            state      <= T_F2_TABLE_WAIT;
          end
        end

        T_F2_TABLE_WAIT: state <= T_F2_TABLE_SUB;

        T_F2_TABLE_SUB: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_SUB;
            fx_a     <= x_q;
            fx_b     <= f2_t_rd;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            issued_q <= 1'b0;
            f2_y_q   <= fx_result;
            if (fx_is_zero(fx_result)) begin
              primary <= f2_t_rd;
              state   <= T_DONE;
            end else begin
              f2_accum_q <= F2_C7;
              f2_step_q  <= 4'd0;
              state      <= T_F2_HORNER;
            end
          end
        end

        T_F2_HORNER: begin
          if (!issued_q) begin
            fx_req <= 1'b1;
            if (!f2_step_q[0]) begin
              fx_op <= FXP_MUL;
              fx_a  <= f2_accum_q;
              fx_b  <= f2_y_q;
            end else begin
              fx_op <= FXP_ADD;
              fx_a  <= f2_coefficient(f2_step_q);
              fx_b  <= f2_accum_q;
            end
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            f2_accum_q <= fx_result;
            issued_q   <= 1'b0;
            if (f2_step_q == 4'd13)
              state <= T_F2_RECONSTRUCT;
            else
              f2_step_q <= f2_step_q + 4'd1;
          end
        end

        T_F2_RECONSTRUCT: begin
          logic signed [31:0] coeff_exp, accum_exp;
          logic [127:0] shifted, coeff_sig, combined;
          coeff_exp = $signed({17'd0, F2_C0[78:64]});
          accum_exp = $signed({17'd0, f2_accum_q[78:64]});
          shifted   = shift128_right_jam(f2_accum_q[63:0], 64'd0,
                                        coeff_exp - accum_exp);
          coeff_sig = {F2_C0[63:0], 64'd0};
          combined  = (f2_accum_q[79] == F2_C0[79])
                    ? coeff_sig + shifted : coeff_sig - shifted;
          wide_a0_q <= combined[127:64];
          wide_a1_q <= combined[63:0];
          wide_b0_q <= f2_y_q[63:0];
          wide_b1_q <= 64'd0;
          wide_cont_q <= WIDE_F2_RECON;
          f2_exp_q  <= coeff_exp +
                       ($signed({17'd0, f2_y_q[78:64]}) - 32'sd16382);
          f2_sign_q <= F2_C0[79] ^ f2_y_q[79];
          state     <= T_WIDE_RESULT;
        end

        T_F2_RECONSTRUCT_TABLE: begin
          wide_a0_q <= f2_sig0_q;
          wide_a1_q <= f2_sig1_q;
          wide_b0_q <= f2_e2_rd[63:0];
          wide_b1_q <= 64'd0;
          wide_cont_q <= WIDE_F2_TABLE;
          state <= T_WIDE_RESULT;
        end

        T_F2_PACK: begin
          primary <= normalize_round_pack(f2_sign_q, f2_exp_q,
                                          f2_sig0_q, f2_sig1_q | 64'd1,
                                          rc_q);
          state <= T_DONE;
        end

        // FYL2X and FYL2XP1 share the same log polynomial.  Classification
        // only prepares registered operands; all floating operations below go
        // through u_shared_fx and all wide products through wide_product.
        T_FY_CLASS: begin
          logic signed [31:0] x_exp_n, y_exp_n;
          logic [63:0] x_sig_n, y_sig_n;
          x_exp_n = $signed({17'd0, x_q[78:64]});
          x_sig_n = x_q[63:0];
          if (x_q[78:64] == 15'd0) begin
            x_exp_n = 32'sd1 - clz64(x_q[63:0]);
            x_sig_n = x_q[63:0] << clz64(x_q[63:0]);
          end
          y_exp_n = $signed({17'd0, y_q[78:64]});
          y_sig_n = y_q[63:0];
          if (y_q[78:64] == 15'd0) begin
            y_exp_n = 32'sd1 - clz64(y_q[63:0]);
            y_sig_n = y_q[63:0] << clz64(y_q[63:0]);
          end

          fy_y_sign_q <= y_q[79];
          fy_y_exp_q  <= y_exp_n;
          fy_y_sig_q  <= y_sig_n;
          flag_pe     <= 1'b1;
          flag_ie     <= 1'b0;

          if (!fy_mode_q) begin
            logic signed [31:0] integer_exp;
            integer_exp = x_exp_n - 32'sd16383;
            if (x_sig_n > FY_SQRT2THR)
              integer_exp = integer_exp + 32'sd1;
            fy_int_exp_q <= integer_exp;
            fy_scaled_q  <= {x_q[79], 15'(x_exp_n - integer_exp), x_sig_n};
            state        <= T_FY_SCALE_SUB;
          end else if ((x_q[78:64] > 15'h3ffd) ||
                       ((x_q[78:64] == 15'h3ffd) &&
                        (x_q[63:0] > (x_q[79]
                         ? 64'h95f619980c4336f7
                         : 64'hd413cccfe7799211)))) begin
            primary <= 80'hffffc000000000000000;
            flag_pe <= 1'b0;
            flag_ie <= 1'b1;
            state   <= T_DONE;
          end else if (fx_is_zero(x_q) || fx_is_zero(y_q) ||
                       (y_exp_n == 32'sd32767)) begin
            issued_q <= 1'b0;
            state    <= T_FY_SPECIAL_MUL;
          end else if (x_exp_n < 32'sd16304) begin
            wide_a0_q       <= FY_LOG2E_H;
            wide_a1_q       <= FY_LOG2E_L;
            wide_b0_q       <= x_sig_n;
            wide_b1_q       <= 64'd0;
            wide_cont_q     <= WIDE_FY_TINY1;
            fy_result_exp_q <= x_exp_n + 32'sd1;
            // T_FY_PACK applies the ST1 sign exactly once for every path.
            fy_result_sign_q<= x_q[79];
            state           <= T_WIDE_RESULT;
          end else begin
            fy_arg_sign_q    <= x_q[79];
            fy_arg_exp_q     <= x_exp_n;
            fy_arg_sig_q     <= x_sig_n;
            fy_result_sign_q <= x_q[79];
            state            <= T_FY_CDIV;
          end
        end

        // scaled - 1.0, extended precision/RNE, for FYL2X range reduction.
        T_FY_SCALE_SUB: begin
          if (!issued_q) begin
            fx_req   <= 1'b1;
            fx_op    <= FXP_ADD;
            fx_a     <= fy_scaled_q;
            fx_b     <= 80'hbfff8000000000000000;
            fx_rc    <= 2'd0;
            fx_pc    <= 2'b11;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            issued_q <= 1'b0;
            if (fx_is_zero(fx_result)) begin
              state <= T_FY_SPECIAL_MUL;
            end else begin
              fy_arg_sign_q    <= fx_result[79];
              fy_arg_exp_q     <= $signed({17'd0, fx_result[78:64]});
              fy_arg_sig_q     <= fx_result[63:0];
              fy_result_sign_q <= fx_result[79];
              state            <= T_FY_CDIV;
            end
          end
        end

        // Exact-power FYL2X and zero/infinity FYL2XP1 cases still use the one
        // shared FP multiplier, with the architected rounding control.
        T_FY_SPECIAL_MUL: begin
          if (!issued_q) begin
            fx_req <= 1'b1;
            fx_op  <= FXP_MUL;
            fx_a   <= fy_mode_q ? x_q
                                : fx_from_int({{32{fy_int_exp_q[31]}},
                                               fy_int_exp_q}, 2'b11);
            fx_b   <= y_q;
            fx_rc  <= rc_q;
            fx_pc  <= 2'b11;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            primary  <= fx_result;
            flag_pe  <= fx_pe;
            issued_q <= 1'b0;
            state    <= T_DONE;
          end
        end

        // The FYL2XP1 tiny path performs two 128x64 products on the same wide
        // multiplier, separated by this explicit register boundary.
        T_FY_TINY_MUL1: begin
          wide_a0_q   <= FY_LOG2E_H;
          wide_a1_q   <= FY_LOG2E_L;
          wide_b0_q   <= x_q[63:0];
          wide_b1_q   <= 64'd0;
          wide_cont_q <= WIDE_FY_TINY1;
          state       <= T_WIDE_RESULT;
        end

        T_FY_TINY_MUL2: begin
          wide_a0_q   <= fy_result_sig0_q;
          wide_a1_q   <= fy_result_sig1_q;
          wide_b0_q   <= fy_y_sig_q;
          wide_b1_q   <= 64'd0;
          wide_cont_q <= WIDE_FY_TINY2;
          state       <= T_WIDE_RESULT;
        end

        // Common t = arg/(2+arg) setup.  The quotient itself is performed by
        // T_QDIV_* and the one u_shared_estdiv instance.
        T_FY_CDIV: begin
          logic signed [31:0] divisor_exp, quotient_exp;
          logic [63:0] divisor_sig0, divisor_sig1;
          logic [63:0] remainder_sig0, remainder_sig1;
          logic [127:0] shifted;
          if (fy_arg_sign_q) begin
            divisor_exp = 32'sd16383;
            shifted = shift128_right_jam(fy_arg_sig_q, 64'd0,
                                         divisor_exp - fy_arg_exp_q);
            divisor_sig0 = shifted[127:64];
            divisor_sig1 = shifted[63:0];
            shifted = 128'd0 - {divisor_sig0, divisor_sig1};
            divisor_sig0 = shifted[127:64];
            divisor_sig1 = shifted[63:0];
          end else begin
            divisor_exp = 32'sd16384;
            shifted = shift128_right_jam(fy_arg_sig_q, 64'd0,
                                         divisor_exp - fy_arg_exp_q);
            divisor_sig0 = shifted[127:64] | 64'h8000000000000000;
            divisor_sig1 = shifted[63:0];
          end
          quotient_exp = fy_arg_exp_q - divisor_exp + 32'sd16382;
          remainder_sig0 = fy_arg_sig_q;
          remainder_sig1 = 64'd0;
          if (divisor_sig0 <= remainder_sig0) begin
            shifted = shift128_right(remainder_sig0, remainder_sig1, 1);
            remainder_sig0 = shifted[127:64];
            remainder_sig1 = shifted[63:0];
            quotient_exp = quotient_exp + 32'sd1;
          end
          q_dsig0_q   <= divisor_sig0;
          q_dsig1_q   <= divisor_sig1;
          q_rsig0_q   <= remainder_sig0;
          q_rsig1_q   <= remainder_sig1;
          q_rsig2_q   <= 64'd0;
          q_exp_q     <= quotient_exp;
          qdiv_cont_q <= QDIV_FY;
          ed_issued_q <= 1'b0;
          state       <= T_QDIV_A;
        end

        T_ATAN_CLASS: begin
          logic signed [31:0] x_exp_n, y_exp_n;
          logic [63:0] x_sig_n, y_sig_n;
          flag_pe <= 1'b1;
          flag_ie <= 1'b0;
          if (fx_is_zero(y_q) && !x_q[79]) begin
            primary <= y_q;
            flag_pe <= 1'b0;
            state   <= T_DONE;
          end else if (($signed({17'd0, x_q[78:64]}) -
                        $signed({17'd0, y_q[78:64]}) >= 32'sd80) &&
                       !x_q[79]) begin
            state <= T_ATAN_FAR_REQ;
          end else begin
            at_result_sign_q <= y_q[79];
            if (fx_is_zero(y_q)) begin
              at_result_exp_q  <= $signed({17'd0, FA_PI_EXP});
              at_result_sig0_q <= FA_PI_H;
              at_result_sig1_q <= FA_PI_L;
              state            <= T_ATAN_PACK;
            end else if (fx_is_zero(x_q) ||
                         ($signed({17'd0, y_q[78:64]}) -
                          $signed({17'd0, x_q[78:64]}) >= 32'sd80)) begin
              at_result_exp_q  <= $signed({17'd0, FA_PI2_EXP});
              at_result_sig0_q <= FA_PI_H;
              at_result_sig1_q <= FA_PI_L;
              state            <= T_ATAN_PACK;
            end else if ($signed({17'd0, x_q[78:64]}) -
                         $signed({17'd0, y_q[78:64]}) >= 32'sd80) begin
              at_result_exp_q  <= $signed({17'd0, FA_PI_EXP});
              at_result_sig0_q <= FA_PI_H;
              at_result_sig1_q <= FA_PI_L;
              state            <= T_ATAN_PACK;
            end else begin
              x_exp_n = $signed({17'd0, x_q[78:64]});
              x_sig_n = x_q[63:0];
              if (x_q[78:64] == 15'd0) begin
                x_exp_n = 32'sd1 - clz64(x_q[63:0]);
                x_sig_n = x_q[63:0] << clz64(x_q[63:0]);
              end
              y_exp_n = $signed({17'd0, y_q[78:64]});
              y_sig_n = y_q[63:0];
              if (y_q[78:64] == 15'd0) begin
                y_exp_n = 32'sd1 - clz64(y_q[63:0]);
                y_sig_n = y_q[63:0] << clz64(y_q[63:0]);
              end
              if ((x_exp_n > y_exp_n) ||
                  ((x_exp_n == y_exp_n) && (x_sig_n >= y_sig_n))) begin
                at_num_exp_q <= y_exp_n;
                at_num_sig_q <= y_sig_n;
                at_den_exp_q <= x_exp_n;
                at_den_sig_q <= x_sig_n;
                if (x_q[79]) begin
                  at_adjust_exp_q  <= $signed({17'd0, FA_PI_EXP});
                  at_adjust_sig0_q <= FA_PI_H;
                  at_adjust_sig1_q <= FA_PI_L;
                  at_adjust_sub_q  <= 1'b1;
                end else begin
                  at_adjust_exp_q  <= 32'sd0;
                  at_adjust_sig0_q <= 64'd0;
                  at_adjust_sig1_q <= 64'd0;
                  at_adjust_sub_q  <= 1'b0;
                end
              end else begin
                at_num_exp_q <= x_exp_n;
                at_num_sig_q <= x_sig_n;
                at_den_exp_q <= y_exp_n;
                at_den_sig_q <= y_sig_n;
                at_adjust_exp_q  <= $signed({17'd0, FA_PI2_EXP});
                at_adjust_sig0_q <= FA_PI_H;
                at_adjust_sig1_q <= FA_PI_L;
                at_adjust_sub_q  <= ~x_q[79];
              end
              state <= T_ATAN_X_SETUP;
            end
          end
        end

        // The old far-ratio shortcut called a full combinational fx_div.  This
        // request instead borrows the parent's already-shared iterative SRT.
        T_ATAN_FAR_REQ: begin
          divide_start <= 1'b1;
          divide_a     <= y_q;
          divide_b     <= x_q;
          divide_rc    <= rc_q;
          state        <= T_ATAN_FAR_WAIT;
        end

        T_ATAN_FAR_WAIT: begin
          if (divide_done) begin
            primary <= divide_result[79:0];
            flag_pe <= 1'b1;
            state   <= T_DONE;
          end
        end

        T_ATAN_X_SETUP: begin
          logic signed [31:0] quotient_exp;
          logic [63:0] remainder_sig0, remainder_sig1;
          logic [127:0] shifted;
          quotient_exp = at_num_exp_q - at_den_exp_q + 32'sd16382;
          remainder_sig0 = at_num_sig_q;
          remainder_sig1 = 64'd0;
          if (at_den_sig_q <= remainder_sig0) begin
            shifted = shift128_right(remainder_sig0, remainder_sig1, 1);
            remainder_sig0 = shifted[127:64];
            remainder_sig1 = shifted[63:0];
            quotient_exp = quotient_exp + 32'sd1;
          end
          q_dsig0_q   <= at_den_sig_q;
          q_dsig1_q   <= 64'd0;
          q_rsig0_q   <= remainder_sig0;
          q_rsig1_q   <= remainder_sig1;
          q_rsig2_q   <= 64'd0;
          q_exp_q     <= quotient_exp;
          qdiv_cont_q <= QDIV_ATAN_X;
          ed_issued_q <= 1'b0;
          state       <= T_QDIV_A;
        end

        // Register the table selection separately.  Keeping fx_to_int and
        // its normalize/round cone in the same state as the guarded y write
        // made the select input of every at_y_sig* D mux depend on at_x
        // through more than 100 logic levels.
        T_ATAN_SPLIT: begin
          logic [79:0] x_times_eight;
          logic signed [63:0] nearest;
          x_times_eight = normalize_round_pack(
              1'b0, at_x_exp_q + 32'sd3,
              at_x_sig0_q, at_x_sig1_q, 2'd0);
          nearest = (x_times_eight[78:64] < 15'h3ffe)
                  ? 64'sd0 : fx_to_int(x_times_eight);
          at_table_index_q <= nearest[3:0];
          state <= T_ATAN_SPLIT_Y;
        end

        // x = t+y, with t equal to the registered nearest n/8 table point.
        T_ATAN_SPLIT_Y: begin
          logic [3:0] table_index;
          int shift;
          logic [63:0] y_sig0, y_sig1, t_sig, unshifted0, unshifted1;
          logic [127:0] difference, shifted;
          logic signed [31:0] t_exp, y_exp_n;
          table_index = at_table_index_q;
          if (table_index == 4'd0) begin
            at_y_sign_q <= 1'b0;
            at_y_exp_q  <= at_x_exp_q;
            at_y_sig0_q <= at_x_sig0_q;
            at_y_sig1_q <= at_x_sig1_q;
            at_t_exp_q  <= 32'sd0;
            at_t_sig_q  <= 64'd0;
          end else begin
            shift = clz32({28'd0, table_index}) + 32;
            t_exp = 32'sd16443 - shift;
            t_sig = {60'd0, table_index} << shift;
            if (t_exp == at_x_exp_q) begin
              difference = {at_x_sig0_q,at_x_sig1_q} - {t_sig,64'd0};
              y_sig0 = difference[127:64];
              y_sig1 = difference[63:0];
              if (!y_sig0[63]) begin
                at_y_sign_q <= 1'b0;
                if (y_sig0 == 64'd0) begin
                  if (y_sig1 == 64'd0)
                    y_exp_n = 32'sd0;
                  else begin
                    shift = clz64(y_sig1) + 64;
                    y_exp_n = at_x_exp_q - shift;
                    difference = shift128_left(y_sig0, y_sig1, shift);
                    y_sig0 = difference[127:64];
                    y_sig1 = difference[63:0];
                  end
                end else begin
                  shift = clz64(y_sig0);
                  y_exp_n = at_x_exp_q - shift;
                  difference = shift128_left(y_sig0, y_sig1, shift);
                  y_sig0 = difference[127:64];
                  y_sig1 = difference[63:0];
                end
              end else begin
                at_y_sign_q <= 1'b1;
                difference = 128'd0 - {y_sig0,y_sig1};
                y_sig0 = difference[127:64];
                y_sig1 = difference[63:0];
                shift = (y_sig0 == 64'd0)
                      ? clz64(y_sig1) + 64 : clz64(y_sig0);
                y_exp_n = at_x_exp_q - shift;
                difference = shift128_left(y_sig0, y_sig1, shift);
                y_sig0 = difference[127:64];
                y_sig1 = difference[63:0];
              end
            end else begin
              shifted = shift128_right_jam(at_x_sig0_q, at_x_sig1_q,
                                           t_exp - at_x_exp_q);
              unshifted0 = shifted[127:64];
              unshifted1 = shifted[63:0];
              at_y_sign_q <= 1'b1;
              difference = {t_sig,64'd0} - {unshifted0,unshifted1};
              y_sig0 = difference[127:64];
              y_sig1 = difference[63:0];
              shift = (y_sig0 == 64'd0)
                    ? clz64(y_sig1) + 64 : clz64(y_sig0);
              y_exp_n = t_exp - shift;
              difference = shift128_left(y_sig0, y_sig1, shift);
              y_sig0 = difference[127:64];
              y_sig1 = difference[63:0];
            end
            at_t_exp_q  <= t_exp;
            at_t_sig_q  <= t_sig;
            at_y_exp_q  <= y_exp_n;
            at_y_sig0_q <= y_sig0;
            at_y_sig1_q <= y_sig1;
          end
          state <= T_ATAN_Z_SETUP;
        end

        // z = y/(1+t*x).  The t*x product uses the shared wide multiplier;
        // WIDE_ATAN_TX then launches the common quotient sequencer.
        T_ATAN_Z_SETUP: begin
          at_z_sign_q <= at_y_sign_q;
          if ((at_t_exp_q == 32'sd0) || (at_y_exp_q == 32'sd0)) begin
            at_z_exp_q  <= at_y_exp_q;
            at_z_sig0_q <= at_y_sig0_q;
            at_z_sig1_q <= at_y_sig1_q;
            state       <= T_ATAN_Z2;
          end else begin
            wide_a0_q   <= at_x_sig0_q;
            wide_a1_q   <= at_x_sig1_q;
            wide_b0_q   <= at_t_sig_q;
            wide_b1_q   <= 64'd0;
            wide_cont_q <= WIDE_ATAN_TX;
            state       <= T_WIDE_RESULT;
          end
        end

        T_ATAN_Z2: begin
          if (at_z_exp_q == 32'sd0) begin
            at_atanz_exp_q  <= 32'sd0;
            at_atanz_sig0_q <= 64'd0;
            at_atanz_sig1_q <= 64'd0;
            state           <= T_ATAN_ATANX;
          end else begin
            wide_a0_q   <= at_z_sig0_q;
            wide_a1_q   <= at_z_sig1_q;
            wide_b0_q   <= at_z_sig0_q;
            wide_b1_q   <= at_z_sig1_q;
            wide_cont_q <= WIDE_ATAN_Z2;
            state       <= T_WIDE_RESULT;
          end
        end

        T_ATAN_HORNER: begin
          if (!issued_q) begin
            fx_req <= 1'b1;
            if (!at_step_q[0]) begin
              fx_op <= FXP_MUL;
              fx_a  <= at_accum_q;
              fx_b  <= at_z2_q;
            end else begin
              fx_op <= FXP_ADD;
              fx_a  <= atan_coefficient(at_step_q);
              fx_b  <= at_accum_q;
            end
            fx_rc    <= 2'd0;
            fx_pc    <= 2'b11;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            at_accum_q <= fx_result;
            issued_q   <= 1'b0;
            if (at_step_q == 4'd10)
              state <= T_ATAN_RECONSTRUCT;
            else
              at_step_q <= at_step_q + 4'd1;
          end
        end

        T_ATAN_RECONSTRUCT: begin
          logic signed [31:0] coeff_exp, accum_exp;
          logic [127:0] shifted, combined;
          coeff_exp = $signed({17'd0, FA_C0[78:64]});
          accum_exp = $signed({17'd0, at_accum_q[78:64]});
          shifted = shift128_right_jam(at_accum_q[63:0], 64'd0,
                                       coeff_exp - accum_exp);
          combined = {FA_C0[63:0],64'd0} - shifted;
          wide_a0_q       <= combined[127:64];
          wide_a1_q       <= combined[63:0];
          wide_b0_q       <= at_z_sig0_q;
          wide_b1_q       <= at_z_sig1_q;
          wide_cont_q     <= WIDE_ATAN_RECON;
          at_atanz_exp_q  <= coeff_exp + at_z_exp_q - 32'sd16382;
          state           <= T_WIDE_RESULT;
        end

        // atan(x) = atan(t) + atan(z), including the table's low correction.
        T_ATAN_ATANX: begin
          logic [79:0] table_high, table_low;
          logic low_sign;
          logic signed [31:0] low_exp, atanx_exp, atanz_exp;
          logic [63:0] low_sig0, low_sig1, atanx_sig0, atanx_sig1;
          logic [63:0] atanz_sig0, atanz_sig1;
          logic [127:0] shifted, combined;
          if (at_t_exp_q == 32'sd0) begin
            at_atanx_exp_q  <= at_atanz_exp_q;
            at_atanx_sig0_q <= at_atanz_sig0_q;
            at_atanx_sig1_q <= at_atanz_sig1_q;
          end else begin
            table_high = FA_HI[at_table_index_q];
            table_low  = FA_LO[at_table_index_q];
            low_sign   = table_low[79];
            low_exp    = $signed({17'd0, table_low[78:64]});
            low_sig0   = table_low[63:0];
            low_sig1   = 64'd0;
            atanx_exp  = $signed({17'd0, table_high[78:64]});
            atanx_sig0 = table_high[63:0];
            atanx_sig1 = 64'd0;
            shifted = shift128_right_jam(low_sig0, low_sig1,
                                         atanx_exp - low_exp);
            combined = low_sign
                     ? ({atanx_sig0,atanx_sig1} - shifted)
                     : ({atanx_sig0,atanx_sig1} + shifted);
            atanx_sig0 = combined[127:64];
            atanx_sig1 = combined[63:0];
            atanz_exp  = at_atanz_exp_q;
            atanz_sig0 = at_atanz_sig0_q;
            atanz_sig1 = at_atanz_sig1_q;
            if (atanz_exp >= atanx_exp) begin
              shifted = shift128_right_jam(atanx_sig0, atanx_sig1,
                                           atanz_exp - atanx_exp + 32'sd1);
              atanx_sig0 = shifted[127:64];
              atanx_sig1 = shifted[63:0];
              atanx_exp  = atanz_exp + 32'sd1;
              shifted = shift128_right_jam(atanz_sig0, atanz_sig1, 1);
              atanz_sig0 = shifted[127:64];
              atanz_sig1 = shifted[63:0];
            end else begin
              shifted = shift128_right_jam(atanx_sig0, atanx_sig1, 1);
              atanx_sig0 = shifted[127:64];
              atanx_sig1 = shifted[63:0];
              shifted = shift128_right_jam(atanz_sig0, atanz_sig1,
                                           atanx_exp - atanz_exp + 32'sd1);
              atanz_sig0 = shifted[127:64];
              atanz_sig1 = shifted[63:0];
              atanx_exp = atanx_exp + 32'sd1;
            end
            combined = at_z_sign_q
                     ? ({atanx_sig0,atanx_sig1} - {atanz_sig0,atanz_sig1})
                     : ({atanx_sig0,atanx_sig1} + {atanz_sig0,atanz_sig1});
            at_atanx_exp_q  <= atanx_exp;
            at_atanx_sig0_q <= combined[127:64];
            at_atanx_sig1_q <= combined[63:0];
          end
          state <= T_ATAN_ADJUST;
        end

        T_ATAN_ADJUST: begin
          logic signed [31:0] adjust_exp, atanx_exp, result_exp_n;
          logic [63:0] adjust_sig0, adjust_sig1, atanx_sig0, atanx_sig1;
          logic [127:0] shifted, combined;
          adjust_exp  = at_adjust_exp_q;
          adjust_sig0 = at_adjust_sig0_q;
          adjust_sig1 = at_adjust_sig1_q;
          atanx_exp   = at_atanx_exp_q;
          atanx_sig0  = at_atanx_sig0_q;
          atanx_sig1  = at_atanx_sig1_q;
          if (adjust_exp == 32'sd0) begin
            at_result_exp_q  <= atanx_exp;
            at_result_sig0_q <= atanx_sig0;
            at_result_sig1_q <= atanx_sig1;
          end else begin
            if (adjust_exp >= atanx_exp) begin
              shifted = shift128_right_jam(atanx_sig0, atanx_sig1,
                                           adjust_exp - atanx_exp + 32'sd1);
              atanx_sig0 = shifted[127:64];
              atanx_sig1 = shifted[63:0];
              result_exp_n = adjust_exp + 32'sd1;
              shifted = shift128_right_jam(adjust_sig0, adjust_sig1, 1);
              adjust_sig0 = shifted[127:64];
              adjust_sig1 = shifted[63:0];
            end else begin
              shifted = shift128_right_jam(atanx_sig0, atanx_sig1, 1);
              atanx_sig0 = shifted[127:64];
              atanx_sig1 = shifted[63:0];
              shifted = shift128_right_jam(adjust_sig0, adjust_sig1,
                                           atanx_exp - adjust_exp + 32'sd1);
              adjust_sig0 = shifted[127:64];
              adjust_sig1 = shifted[63:0];
              result_exp_n = atanx_exp + 32'sd1;
            end
            combined = at_adjust_sub_q
                     ? ({adjust_sig0,adjust_sig1} - {atanx_sig0,atanx_sig1})
                     : ({adjust_sig0,adjust_sig1} + {atanx_sig0,atanx_sig1});
            at_result_exp_q  <= result_exp_n;
            at_result_sig0_q <= combined[127:64];
            at_result_sig1_q <= combined[63:0];
          end
          state <= T_ATAN_PACK;
        end

        T_ATAN_PACK: begin
          primary <= normalize_round_pack(at_result_sign_q, at_result_exp_q,
                                          at_result_sig0_q,
                                          at_result_sig1_q | 64'd1, rc_q);
          state <= T_DONE;
        end

        T_QDIV_A: begin
          if (!ed_issued_q) begin
            ed_req      <= 1'b1;
            ed_a0       <= q_rsig0_q;
            ed_a1       <= q_rsig1_q;
            ed_issued_q <= 1'b1;
          end else if (ed_vld) begin
            q_sig0_q    <= ed_z;
            ed_issued_q <= 1'b0;
            state       <= T_QDIV_B;
          end
        end

        T_QDIV_B: begin
          wide_a0_q   <= q_dsig0_q;
          wide_a1_q   <= q_dsig1_q;
          wide_b0_q   <= q_sig0_q;
          wide_b1_q   <= 64'd0;
          wide_cont_q <= WIDE_QDIV;
          state       <= T_WIDE_RESULT;
        end

        T_QDIV_C: begin
          if (q_rsig0_q[63] && (q_correction_q != 3'd6)) begin
            logic [191:0] corrected;
            corrected = {q_rsig0_q, q_rsig1_q, q_rsig2_q} +
                        {64'd0, q_dsig0_q, q_dsig1_q};
            q_sig0_q      <= q_sig0_q - 64'd1;
            q_rsig0_q     <= corrected[191:128];
            q_rsig1_q     <= corrected[127:64];
            q_rsig2_q     <= corrected[63:0];
            q_correction_q<= q_correction_q + 3'd1;
          end else begin
            ed_issued_q <= 1'b0;
            state       <= T_QDIV_D;
          end
        end

        T_QDIV_D: begin
          if (!ed_issued_q) begin
            ed_req      <= 1'b1;
            ed_a0       <= q_rsig1_q;
            ed_a1       <= q_rsig2_q;
            ed_issued_q <= 1'b1;
          end else if (ed_vld) begin
            ed_issued_q <= 1'b0;
            unique case (qdiv_cont_q)
              QDIV_FY: begin
                fy_t_sig0_q <= q_sig0_q;
                fy_t_sig1_q <= ed_z;
                fy_t_exp_q  <= q_exp_q;
                state       <= T_FY_CT2;
              end
              QDIV_ATAN_X: begin
                at_x_sig0_q <= q_sig0_q;
                at_x_sig1_q <= ed_z;
                at_x_exp_q  <= q_exp_q;
                state       <= T_ATAN_SPLIT;
              end
              QDIV_ATAN_Z: begin
                at_z_sig0_q <= q_sig0_q;
                at_z_sig1_q <= ed_z;
                at_z_exp_q  <= q_exp_q;
                state       <= T_ATAN_Z2;
              end
              default: state <= T_DONE;
            endcase
          end
        end

        T_FY_CT2: begin
          wide_a0_q   <= fy_t_sig0_q;
          wide_a1_q   <= fy_t_sig1_q;
          wide_b0_q   <= fy_t_sig0_q;
          wide_b1_q   <= fy_t_sig1_q;
          wide_cont_q <= WIDE_FY_T2;
          state       <= T_WIDE_RESULT;
        end

        T_FY_HORNER: begin
          if (!issued_q) begin
            fx_req <= 1'b1;
            if (!fy_step_q[0]) begin
              fx_op <= FXP_MUL;
              fx_a  <= fy_accum_q;
              fx_b  <= fy_t2_q;
            end else begin
              fx_op <= FXP_ADD;
              fx_a  <= fy_coefficient(fy_step_q);
              fx_b  <= fy_accum_q;
            end
            fx_rc    <= 2'd0;
            fx_pc    <= 2'b11;
            issued_q <= 1'b1;
          end else if (fx_vld) begin
            fy_accum_q <= fx_result;
            issued_q   <= 1'b0;
            if (fy_step_q == 5'd17)
              state <= T_FY_RECONSTRUCT;
            else
              fy_step_q <= fy_step_q + 5'd1;
          end
        end

        T_FY_RECONSTRUCT: begin
          logic signed [31:0] coeff_exp, accum_exp;
          logic [127:0] shifted, combined;
          coeff_exp = $signed({17'd0, FY_C0[78:64]});
          accum_exp = $signed({17'd0, fy_accum_q[78:64]});
          shifted = shift128_right_jam(fy_accum_q[63:0], 64'd0,
                                       coeff_exp - accum_exp);
          combined = (FY_C0[79] == fy_accum_q[79])
                   ? ({FY_C0[63:0],64'd0} + shifted)
                   : ({FY_C0[63:0],64'd0} - shifted);
          wide_a0_q       <= combined[127:64];
          wide_a1_q       <= combined[63:0];
          wide_b0_q       <= fy_t_sig0_q;
          wide_b1_q       <= fy_t_sig1_q;
          wide_cont_q     <= WIDE_FY_RECON;
          fy_result_exp_q <= coeff_exp + fy_t_exp_q - 32'sd16382;
          state           <= T_WIDE_RESULT;
        end

        T_FY_POST_COMBINE: begin
          logic result_sign;
          logic signed [31:0] result_exp;
          logic [63:0] result_sig0, result_sig1;
          result_sign = fy_result_sign_q;
          result_exp  = fy_result_exp_q;
          result_sig0 = fy_result_sig0_q;
          result_sig1 = fy_result_sig1_q;
          if (!fy_mode_q && (fy_int_exp_q != 32'sd0)) begin
            logic integer_sign;
            logic signed [31:0] magnitude, integer_value_exp;
            logic [63:0] integer_sig;
            logic [127:0] shifted, combined;
            int shift;
            integer_sign = fy_int_exp_q[31];
            magnitude = integer_sign ? -fy_int_exp_q : fy_int_exp_q;
            shift = clz32(magnitude) + 32;
            integer_sig = {32'd0, magnitude} << shift;
            integer_value_exp = 32'sd16446 - shift;
            shifted = shift128_right_jam(result_sig0, result_sig1,
                                         integer_value_exp - result_exp);
            combined = (result_sign == integer_sign)
                     ? ({integer_sig,64'd0} + shifted)
                     : ({integer_sig,64'd0} - shifted);
            result_sig0 = combined[127:64];
            result_sig1 = combined[63:0];
            result_exp  = integer_value_exp;
            result_sign = integer_sign;
          end
          fy_result_sign_q <= result_sign;
          fy_result_exp_q  <= result_exp;
          fy_result_sig0_q <= result_sig0;
          fy_result_sig1_q <= result_sig1;
          state            <= T_FY_POST_MUL;
        end

        T_FY_POST_MUL: begin
          wide_a0_q   <= fy_result_sig0_q;
          wide_a1_q   <= fy_result_sig1_q;
          wide_b0_q   <= fy_y_sig_q;
          wide_b1_q   <= 64'd0;
          wide_cont_q <= WIDE_FY_POST;
          state       <= T_WIDE_RESULT;
        end

        T_FY_PACK: begin
          primary <= normalize_round_pack(fy_result_sign_q ^ fy_y_sign_q,
                                          fy_result_exp_q,
                                          fy_result_sig0_q,
                                          fy_result_sig1_q,
                                          rc_q);
          flag_pe <= 1'b1;
          state   <= T_DONE;
        end

        // Registered output side of the single iterative wide multiplier.
        T_WIDE_RESULT: begin
          if (!wide_issued_q) begin
            wide_start    <= 1'b1;
            wide_issued_q <= 1'b1;
          end else if (wide_done) begin
            wide_issued_q <= 1'b0;
            unique case (wide_cont_q)
            WIDE_F2_TINY: begin
              f2_sig0_q <= wide_product[255:192];
              f2_sig1_q <= wide_product[191:128] | 64'd1;
              state     <= T_F2_PACK;
            end
            WIDE_F2_RECON: begin
              f2_sig0_q <= wide_product[255:192];
              f2_sig1_q <= wide_product[191:128];
              state     <= (f2_index_q == 7'd32)
                         ? T_F2_PACK : T_F2_RECONSTRUCT_TABLE;
            end
            WIDE_F2_TABLE: begin
              logic signed [31:0] e2_exp, b_exp, a_exp;
              logic [127:0] a_sig, b_sig;
              logic b_sign;
              e2_exp = $signed({17'd0, f2_e2_rd[78:64]});
              a_exp  = f2_exp_q + (e2_exp - 32'sd16382);
              a_sig  = wide_product[255:128];
              b_exp  = $signed({17'd0, f2_em_rd[78:64]});
              b_sig  = {f2_em_rd[63:0], 64'd0};
              if (b_exp < a_exp)
                b_sig = shift128_right_jam(f2_em_rd[63:0], 64'd0,
                                           a_exp - b_exp);
              else if (a_exp < b_exp) begin
                a_sig = shift128_right_jam(a_sig[127:64], a_sig[63:0],
                                           b_exp - a_exp);
                a_exp = b_exp;
              end
              b_sign = f2_em_rd[79];
              if (f2_sign_q == b_sign) begin
                a_sig = shift128_right_jam(a_sig[127:64], a_sig[63:0], 1);
                b_sig = shift128_right_jam(b_sig[127:64], b_sig[63:0], 1);
                a_exp = a_exp + 32'sd1;
                a_sig = a_sig + b_sig;
                f2_sig0_q <= a_sig[127:64];
                f2_sig1_q <= a_sig[63:0];
                f2_exp_q  <= a_exp;
              end else begin
                a_sig = b_sig - a_sig;
                f2_sig0_q <= a_sig[127:64];
                f2_sig1_q <= a_sig[63:0];
                f2_exp_q  <= a_exp;
                f2_sign_q <= b_sign;
              end
              state <= T_F2_PACK;
            end
            WIDE_QDIV: begin
              logic [191:0] remainder;
              remainder = {q_rsig0_q, q_rsig1_q, q_rsig2_q} -
                          wide_product[255:64];
              q_rsig0_q      <= remainder[191:128];
              q_rsig1_q      <= remainder[127:64];
              q_rsig2_q      <= remainder[63:0];
              q_correction_q <= 3'd0;
              state          <= T_QDIV_C;
            end
            WIDE_FY_TINY1: begin
              fy_result_sig0_q <= wide_product[255:192];
              fy_result_sig1_q <= wide_product[191:128];
              state            <= T_FY_TINY_MUL2;
            end
            WIDE_FY_TINY2: begin
              fy_result_sig0_q <= wide_product[255:192];
              fy_result_sig1_q <= wide_product[191:128] | 64'd1;
              fy_result_exp_q  <= fy_result_exp_q +
                                  (fy_y_exp_q - 32'sd16382);
              state            <= T_FY_PACK;
            end
            WIDE_FY_T2: begin
              fy_t2_q <= normalize_round_pack(
                  1'b0, fy_t_exp_q + fy_t_exp_q - 32'sd16382,
                  wide_product[255:192], wide_product[191:128], 2'd0);
              fy_accum_q <= FY_C9;
              fy_step_q  <= 5'd0;
              issued_q   <= 1'b0;
              state      <= T_FY_HORNER;
            end
            WIDE_FY_RECON: begin
              fy_result_sig0_q <= wide_product[255:192];
              fy_result_sig1_q <= wide_product[191:128];
              state            <= T_FY_POST_COMBINE;
            end
            WIDE_FY_POST: begin
              fy_result_sig0_q <= wide_product[255:192];
              fy_result_sig1_q <= wide_product[191:128] | 64'd1;
              fy_result_exp_q  <= fy_result_exp_q +
                                  (fy_y_exp_q - 32'sd16382);
              state            <= T_FY_PACK;
            end
            WIDE_ATAN_TX: begin
              logic signed [31:0] divisor_exp, quotient_exp;
              logic [63:0] divisor_sig0, divisor_sig1;
              logic [63:0] remainder_sig0, remainder_sig1;
              logic [127:0] shifted;
              divisor_exp = at_t_exp_q + at_x_exp_q - 32'sd16382;
              divisor_sig0 = wide_product[255:192];
              divisor_sig1 = wide_product[191:128];
              shifted = shift128_right_jam(divisor_sig0, divisor_sig1,
                                           32'sh3fff - divisor_exp);
              divisor_sig0 = shifted[127:64] | 64'h8000000000000000;
              divisor_sig1 = shifted[63:0];
              quotient_exp = at_y_exp_q - 32'sd1;
              remainder_sig0 = at_y_sig0_q;
              remainder_sig1 = at_y_sig1_q;
              if (divisor_sig0 <= remainder_sig0) begin
                shifted = shift128_right(remainder_sig0, remainder_sig1, 1);
                remainder_sig0 = shifted[127:64];
                remainder_sig1 = shifted[63:0];
                quotient_exp = quotient_exp + 32'sd1;
              end
              q_dsig0_q   <= divisor_sig0;
              q_dsig1_q   <= divisor_sig1;
              q_rsig0_q   <= remainder_sig0;
              q_rsig1_q   <= remainder_sig1;
              q_rsig2_q   <= 64'd0;
              q_exp_q     <= quotient_exp;
              qdiv_cont_q <= QDIV_ATAN_Z;
              ed_issued_q <= 1'b0;
              state       <= T_QDIV_A;
            end
            WIDE_ATAN_Z2: begin
              at_z2_q <= normalize_round_pack(
                  1'b0, at_z_exp_q + at_z_exp_q - 32'sd16382,
                  wide_product[255:192], wide_product[191:128], 2'd0);
              at_accum_q <= FA_C6;
              at_step_q  <= 4'd0;
              issued_q   <= 1'b0;
              state      <= T_ATAN_HORNER;
            end
            WIDE_ATAN_RECON: begin
              at_atanz_sig0_q <= wide_product[255:192];
              at_atanz_sig1_q <= wide_product[191:128];
              state           <= T_ATAN_ATANX;
            end
            default: state <= T_DONE;
            endcase
          end
        end

        T_DONE: begin
          done  <= 1'b1;
          state <= T_IDLE;
        end

        default: state <= T_IDLE;
      endcase
    end
  end

  wire logic _unused_ok = &{1'b0, y_q, rc_q, fx_pe, wide_busy};

endmodule

`default_nettype wire
