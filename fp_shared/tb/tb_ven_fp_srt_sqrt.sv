`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_srt_sqrt;
  import fpu_x87_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic start, busy, done;
  logic [79:0] a;
  logic [1:0] rc;
  logic [82:0] result;
  logic [2:0] rem_q012;
  logic rem_c2, rem_ie;
  int checks;

  fpu_srt_div dut (
      .clk(clk), .rst_n(rst_n), .start(start), .mode(2'd1),
      .prem1(1'b0), .a(a), .b(80'd0), .rc(rc), .pc(2'b11),
      .buggy(1'b0), .busy(busy), .done(done), .result(result),
      .rem_q012(rem_q012), .rem_c2(rem_c2), .rem_ie(rem_ie)
  );

  task automatic check_one(input logic [79:0] value,
                           input logic [1:0] rounding);
    logic [80:0] expected;
    int timeout;
    begin
      while (busy) @(negedge clk);
      expected = fx_sqrt(value, rounding, 2'b11);
      a = value;
      rc = rounding;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      timeout = 0;
      while (!done) begin
        @(negedge clk);
        timeout++;
        if (timeout > 60)
          $fatal(1, "SRT sqrt timeout x=%020h rc=%0d", value, rounding);
      end
      if (result[80:0] !== expected)
        $fatal(1, "SRT sqrt mismatch x=%020h rc=%0d got=%021h exp=%021h",
               value, rounding, result[80:0], expected);
      checks++;
    end
  endtask

  initial begin
    start = 1'b0;
    a = 80'd0;
    rc = 2'd0;
    checks = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int r = 0; r < 4; r++) begin
      check_one(80'h3fff8000000000000000, 2'(r));
      check_one(80'h40008000000000000000, 2'(r));
      check_one(80'h4001_8000000000000000, 2'(r));
      for (int i = 0; i < 2000; i++) begin
        logic [63:0] significand;
        logic [14:0] exponent;
        significand = {$urandom, $urandom} | 64'h8000000000000000;
        exponent = 15'(15'h3f00 + ($urandom % 32'd512));
        check_one({1'b0, exponent, significand}, 2'(r));
      end
    end

    $display("VEN-FP-SRT-SQRT-A-B-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
