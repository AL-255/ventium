`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_trans;
  import ventium_decode_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic start;
  fxop_e op;
  logic [79:0] x, y;
  logic [1:0] rc;

  logic new_busy, new_done, new_c2, new_ie, new_pe;
  logic [79:0] new_primary, new_secondary;
  logic old_busy, old_done, old_c2;
  logic [79:0] old_sin, old_cos;
  logic f2_busy, f2_done, f2_pe, f2_ie;
  logic [79:0] f2_result;
  logic fy_busy, fy_done, fy_pe, fy_ie;
  logic [79:0] fy_result;
  logic atan_busy, atan_done, atan_pe, atan_ie;
  logic [79:0] atan_result;
  logic dut_div_start, dut_div_busy, dut_div_done;
  logic [79:0] dut_div_a, dut_div_b;
  logic [1:0] dut_div_rc;
  logic [82:0] dut_div_result;
  logic [2:0] dut_div_q;
  logic dut_div_c2, dut_div_ie;
  logic dut_fx_req, dut_fx_vld, dut_fx_pe, dut_fx_busy;
  logic [1:0] dut_fx_op, dut_fx_rc, dut_fx_pc;
  logic [79:0] dut_fx_a, dut_fx_b, dut_fx_result;
  logic [84:0] dut_fx_full_result;
  int checks;

  ven_fp_trans dut (
      .clk(clk), .rst_n(rst_n), .start(start), .op(op),
      .x(x), .y(y), .rc(rc),
      .fx_req(dut_fx_req), .fx_op(dut_fx_op),
      .fx_a(dut_fx_a), .fx_b(dut_fx_b),
      .fx_rc(dut_fx_rc), .fx_pc(dut_fx_pc),
      .fx_vld(dut_fx_vld), .fx_result(dut_fx_result),
      .fx_pe(dut_fx_pe),
      .divide_start(dut_div_start), .divide_a(dut_div_a),
      .divide_b(dut_div_b), .divide_rc(dut_div_rc),
      .divide_done(dut_div_done), .divide_result(dut_div_result[79:0]),
      .busy(new_busy), .done(new_done),
      .primary(new_primary), .secondary(new_secondary),
      .flag_c2(new_c2), .flag_ie(new_ie), .flag_pe(new_pe)
  );

  wire logic [2:0] dut_fx_subop = (dut_fx_op == 2'd0) ? 3'd0
                                    : (dut_fx_op == 2'd1) ? 3'd1
                                    : (dut_fx_op == 2'd2) ? 3'd4 : 3'd5;
  assign dut_fx_result = dut_fx_full_result[79:0];
  assign dut_fx_pe     = dut_fx_full_result[80];

  ven_fp_alu dut_shared_fx (
      .clk(clk), .rst_n(rst_n), .start(dut_fx_req),
      .subop(dut_fx_subop), .operand_a(dut_fx_a), .operand_b(dut_fx_b),
      .rc(dut_fx_rc), .pc(dut_fx_pc), .busy(dut_fx_busy),
      .done(dut_fx_vld), .result(dut_fx_full_result)
  );

  fpu_srt_div dut_divider (
      .clk(clk), .rst_n(rst_n), .start(dut_div_start),
      .mode(2'd0), .prem1(1'b0), .a(dut_div_a), .b(dut_div_b),
      .rc(dut_div_rc), .pc(2'b11), .buggy(1'b0),
      .busy(dut_div_busy), .done(dut_div_done), .result(dut_div_result),
      .rem_q012(dut_div_q), .rem_c2(dut_div_c2), .rem_ie(dut_div_ie)
  );

  fpu_fsincos reference (
      .clk(clk), .rst_n(rst_n),
      .start(start && ((op == FX_FSIN) || (op == FX_FCOS) ||
                       (op == FX_FSINCOS) || (op == FX_FPTAN))), .x(x),
      .busy(old_busy), .done(old_done),
      .sin_o(old_sin), .cos_o(old_cos), .c2_o(old_c2)
  );

  fpu_fyl2x reference_fy (
      .clk(clk), .rst_n(rst_n),
      .start(start && ((op == FX_FYL2X) || (op == FX_FYL2XP1))),
      .mode(op == FX_FYL2XP1), .y(y), .x(x), .rc(rc),
      .busy(fy_busy), .done(fy_done), .result(fy_result),
      .inexact(fy_pe), .invalid(fy_ie)
  );

  fpu_fpatan reference_atan (
      .clk(clk), .rst_n(rst_n), .start(start && (op == FX_FPATAN)),
      .y(y), .x(x), .rc(rc), .busy(atan_busy), .done(atan_done),
      .result(atan_result), .inexact(atan_pe), .invalid(atan_ie)
  );

  fpu_f2xm1 reference_f2 (
      .clk(clk), .rst_n(rst_n), .start(start && (op == FX_F2XM1)),
      .x(x), .rc(rc), .busy(f2_busy), .done(f2_done),
      .result(f2_result), .inexact(f2_pe), .invalid(f2_ie)
  );

  function automatic fxop_e select_op(input int value);
    unique case (value & 3)
      0: return FX_FSIN;
      1: return FX_FCOS;
      2: return FX_FSINCOS;
      default: return FX_FPTAN;
    endcase
  endfunction

  task automatic compare_one(input fxop_e which, input logic [79:0] value);
    logic seen_new, seen_old;
    logic [79:0] got_primary, got_secondary, got_sin, got_cos;
    logic got_new_c2, got_old_c2, got_ie, got_pe;
    int timeout;
    begin
      while (new_busy || old_busy || dut_fx_busy) @(negedge clk);
      op = which;
      x = value;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      seen_new = 1'b0;
      seen_old = 1'b0;
      timeout = 0;
      while (!(seen_new && seen_old)) begin
        @(negedge clk);
        if (new_done) begin
          seen_new     = 1'b1;
          got_primary  = new_primary;
          got_secondary= new_secondary;
          got_new_c2   = new_c2;
          got_ie       = new_ie;
          got_pe       = new_pe;
        end
        if (old_done) begin
          seen_old   = 1'b1;
          got_sin    = old_sin;
          got_cos    = old_cos;
          got_old_c2 = old_c2;
        end
        timeout++;
        if (timeout > 1000)
          $fatal(1, "trans timeout op=%0d x=%020h", which, value);
      end

      if (got_new_c2 !== got_old_c2 || got_ie !== 1'b0 ||
          got_pe !== !got_old_c2 || got_secondary !== got_cos ||
          got_primary !== ((which == FX_FCOS) ? got_cos : got_sin))
        $fatal(1,
          "trans A/B mismatch op=%0d x=%020h new=%020h/%020h c2=%0b ie=%0b pe=%0b old=%020h/%020h c2=%0b",
          which, value, got_primary, got_secondary, got_new_c2, got_ie,
          got_pe, got_sin, got_cos, got_old_c2);
      checks++;
    end
  endtask

  task automatic compare_atan(input logic [79:0] y_value,
                              input logic [79:0] x_value,
                              input logic [1:0] rounding);
    logic seen_new, seen_old;
    logic [79:0] got_new, got_old;
    logic got_new_ie, got_new_pe, got_old_ie, got_old_pe;
    int timeout;
    begin
      while (new_busy || atan_busy || dut_div_busy) @(negedge clk);
      op = FX_FPATAN;
      x = x_value;
      y = y_value;
      rc = rounding;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      seen_new = 1'b0;
      seen_old = 1'b0;
      timeout = 0;
      while (!(seen_new && seen_old)) begin
        @(negedge clk);
        if (new_done) begin
          seen_new   = 1'b1;
          got_new    = new_primary;
          got_new_ie = new_ie;
          got_new_pe = new_pe;
        end
        if (atan_done) begin
          seen_old   = 1'b1;
          got_old    = atan_result;
          got_old_ie = atan_ie;
          got_old_pe = atan_pe;
        end
        timeout++;
        if (timeout > 5000)
          $fatal(1, "FPATAN timeout rc=%0d y=%020h x=%020h",
                 rounding, y_value, x_value);
      end
      if (got_new !== got_old || got_new_ie !== got_old_ie ||
          got_new_pe !== got_old_pe)
        $fatal(1,
          "FPATAN A/B mismatch rc=%0d y=%020h x=%020h new=%020h ie=%0b pe=%0b old=%020h ie=%0b pe=%0b",
          rounding, y_value, x_value, got_new, got_new_ie, got_new_pe,
          got_old, got_old_ie, got_old_pe);
      checks++;
    end
  endtask

  task automatic compare_fy(input fxop_e which,
                            input logic [79:0] y_value,
                            input logic [79:0] x_value,
                            input logic [1:0] rounding);
    logic seen_new, seen_old;
    logic [79:0] got_new, got_old;
    logic got_new_ie, got_new_pe, got_old_ie, got_old_pe;
    int timeout;
    begin
      while (new_busy || fy_busy) @(negedge clk);
      op = which;
      x = x_value;
      y = y_value;
      rc = rounding;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      seen_new = 1'b0;
      seen_old = 1'b0;
      timeout = 0;
      while (!(seen_new && seen_old)) begin
        @(negedge clk);
        if (new_done) begin
          seen_new   = 1'b1;
          got_new    = new_primary;
          got_new_ie = new_ie;
          got_new_pe = new_pe;
        end
        if (fy_done) begin
          seen_old   = 1'b1;
          got_old    = fy_result;
          got_old_ie = fy_ie;
          got_old_pe = fy_pe;
        end
        timeout++;
        if (timeout > 3000)
          $fatal(1, "FYL2X timeout op=%0d rc=%0d y=%020h x=%020h",
                 which, rounding, y_value, x_value);
      end
      if (got_new !== got_old || got_new_ie !== got_old_ie ||
          got_new_pe !== got_old_pe)
        $fatal(1,
          "FYL2X A/B mismatch op=%0d rc=%0d y=%020h x=%020h new=%020h ie=%0b pe=%0b old=%020h ie=%0b pe=%0b signs=%0b/%0b mode=%0b",
          which, rounding, y_value, x_value, got_new, got_new_ie,
          got_new_pe, got_old, got_old_ie, got_old_pe,
          dut.fy_result_sign_q, dut.fy_y_sign_q, dut.fy_mode_q);
      checks++;
    end
  endtask

  task automatic compare_f2(input logic [79:0] value,
                            input logic [1:0] rounding);
    logic seen_new, seen_old;
    logic [79:0] got_new, got_old;
    logic got_new_ie, got_new_pe, got_old_ie, got_old_pe;
    int timeout;
    begin
      while (new_busy || f2_busy) @(negedge clk);
      op = FX_F2XM1;
      x = value;
      rc = rounding;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      seen_new = 1'b0;
      seen_old = 1'b0;
      timeout = 0;
      while (!(seen_new && seen_old)) begin
        @(negedge clk);
        if (new_done) begin
          seen_new  = 1'b1;
          got_new   = new_primary;
          got_new_ie= new_ie;
          got_new_pe= new_pe;
        end
        if (f2_done) begin
          seen_old  = 1'b1;
          got_old   = f2_result;
          got_old_ie= f2_ie;
          got_old_pe= f2_pe;
        end
        timeout++;
        if (timeout > 1000)
          $fatal(1, "F2XM1 timeout rc=%0d x=%020h", rounding, value);
      end
      if (got_new !== got_old || got_new_ie !== got_old_ie ||
          got_new_pe !== got_old_pe)
        $fatal(1,
          "F2XM1 A/B mismatch rc=%0d x=%020h new=%020h ie=%0b pe=%0b old=%020h ie=%0b pe=%0b",
          rounding, value, got_new, got_new_ie, got_new_pe,
          got_old, got_old_ie, got_old_pe);
      checks++;
    end
  endtask

  initial begin
    logic [63:0] mantissa;
    logic [14:0] exponent;
    logic sign;
    int signed delta;

    start = 1'b0;
    op = FX_FSIN;
    x = 80'd0;
    y = 80'd0;
    rc = 2'd0;
    checks = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int k = 0; k < 4; k++) begin
      compare_one(select_op(k), 80'h00000000000000000000);
      compare_one(select_op(k), 80'h80000000000000000000);
      compare_one(select_op(k), 80'h3fff8000000000000000);
      compare_one(select_op(k), 80'hbfff8000000000000000);
      compare_one(select_op(k), 80'h4000c90fdaa22168c235);
      compare_one(select_op(k), 80'h403e8000000000000000);
    end

    for (int k = 0; k < 256; k++) begin
      delta = $signed($urandom_range(0, 80)) - 40;
      exponent = 15'(32'sh3fff + delta);
      mantissa = {$urandom, $urandom};
      mantissa[63] = 1'b1;
      sign = 1'($urandom_range(0,1));
      compare_one(select_op(k), {sign, exponent, mantissa});
    end

    for (int r = 0; r < 4; r++) begin
      compare_f2(80'h00000000000000000000, r[1:0]);
      compare_f2(80'h80000000000000000000, r[1:0]);
      compare_f2(80'h3fff8000000000000000, r[1:0]);
      compare_f2(80'hbfff8000000000000000, r[1:0]);
      compare_f2(80'h3ffe8000000000000000, r[1:0]);
      compare_f2(80'hbffe8000000000000000, r[1:0]);
      compare_f2(80'h3fb08000000000000000, r[1:0]);
      compare_f2(80'h3faf8000000000000000, r[1:0]);
      for (int k = 0; k < 128; k++) begin
        exponent = 15'(15'h3f60 + $urandom_range(0, 159));
        mantissa = {$urandom, $urandom};
        mantissa[63] = 1'b1;
        sign = 1'($urandom_range(0,1));
        compare_f2({sign, exponent, mantissa}, r[1:0]);
      end
    end

    for (int r = 0; r < 4; r++) begin
      compare_atan(80'h00000000000000000000,
                   80'h3fff8000000000000000, r[1:0]);
      compare_atan(80'h80000000000000000000,
                   80'hbfff8000000000000000, r[1:0]);
      compare_atan(80'h3fff8000000000000000,
                   80'h3fff8000000000000000, r[1:0]);
      compare_atan(80'hbfff8000000000000000,
                   80'h3fff8000000000000000, r[1:0]);
      compare_atan(80'h3fff8000000000000000,
                   80'hbfff8000000000000000, r[1:0]);
      compare_atan(80'h3f008000000000000000,
                   80'h40008000000000000000, r[1:0]);
      for (int k = 0; k < 64; k++) begin
        logic [79:0] random_y, random_x;
        random_y = {1'($urandom_range(0,1)),
                    15'(15'h3f00 + $urandom_range(0, 511)),
                    1'b1, 63'({$urandom, $urandom})};
        random_x = {1'($urandom_range(0,1)),
                    15'(15'h3f00 + $urandom_range(0, 511)),
                    1'b1, 63'({$urandom, $urandom})};
        compare_atan(random_y, random_x, r[1:0]);
      end
    end

    for (int r = 0; r < 4; r++) begin
      compare_fy(FX_FYL2X, 80'h3fff8000000000000000,
                 80'h3fff8000000000000000, r[1:0]);
      compare_fy(FX_FYL2X, 80'hbfff8000000000000000,
                 80'h40008000000000000000, r[1:0]);
      compare_fy(FX_FYL2X, 80'h40008000000000000000,
                 80'h3ffe8000000000000000, r[1:0]);
      compare_fy(FX_FYL2XP1, 80'h3fff8000000000000000,
                 80'h00000000000000000000, r[1:0]);
      compare_fy(FX_FYL2XP1, 80'hbfff8000000000000000,
                 80'h3ffd8000000000000000, r[1:0]);
      compare_fy(FX_FYL2XP1, 80'h3fff8000000000000000,
                 80'h3ffe8000000000000000, r[1:0]);
      for (int k = 0; k < 64; k++) begin
        logic [79:0] random_y, random_x;
        random_y = {1'($urandom_range(0,1)),
                    15'(15'h3f80 + $urandom_range(0, 255)),
                    1'b1, 63'({$urandom, $urandom})};
        random_x = {1'b0,
                    15'(15'h3f80 + $urandom_range(0, 255)),
                    1'b1, 63'({$urandom, $urandom})};
        compare_fy(FX_FYL2X, random_y, random_x, r[1:0]);
        random_x = {1'($urandom_range(0,1)),
                    15'(15'h3f00 + $urandom_range(0, 252)),
                    1'b1, 63'({$urandom, $urandom})};
        compare_fy(FX_FYL2XP1, random_y, random_x, r[1:0]);
      end
    end

    $display("VEN-FP-TRANS-A-B-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
