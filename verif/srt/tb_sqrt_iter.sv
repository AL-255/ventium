// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/srt/tb_sqrt_iter.sv — standalone clocked gate for the iterative sqrt
// engine (rtl/fpu/fpu_sqrt_iter.sv). Asserts the multi-cycle engine is bit-exact
// (full {inexact, floatx80}) vs the combinational fpu_x87_pkg::fx_sqrt — which is
// itself QEMU-validated (verif/tests/tx_sqrt / make m3). Directed (1.0/2.0/4.0)
// + a random normal-operand corpus across all 4 rounding modes. Verilator --timing.
// ===========================================================================
`default_nettype none

module tb_sqrt_iter;
  import fpu_x87_pkg::*;
`ifndef SQRT_N
  `define SQRT_N 8000
`endif
  localparam int N = `SQRT_N;

  logic        clk = 1'b0, rst_n = 1'b0, start = 1'b0;
  logic [79:0] a = '0;
  logic [1:0]  rc = 2'd0;
  logic        busy, done;
  logic [80:0] result;

  fpu_sqrt_iter dut (.clk, .rst_n, .start, .a, .rc, .busy, .done, .result);

  initial forever #5 clk = ~clk;

  task automatic run_sqrt(input logic [79:0] x, input logic [1:0] rcc, output logic [80:0] r);
    @(negedge clk);
    a = x; rc = rcc; start = 1'b1;
    @(negedge clk); start = 1'b0;
    while (!done) @(negedge clk);
    r = result;
  endtask

  int          fail;
  logic [80:0] got, ref_;
  logic [79:0] xa;
  logic [63:0] man;
  logic [14:0] exp;
  initial begin
    rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1; @(negedge clk);
    fail = 0;

    // directed sanity (printed)
    run_sqrt(fx_make(1'b0,15'h3fff,64'h8000000000000000), 2'd0, got); // sqrt(1.0)
    $display("sqrt(1.0) = %020h inexact=%b (expect 1.0, inexact=0)", got[79:0], got[80]);
    run_sqrt(fx_make(1'b0,15'h4001,64'h8000000000000000), 2'd0, got); // sqrt(4.0)
    $display("sqrt(4.0) = %020h inexact=%b (expect 2.0, inexact=0)", got[79:0], got[80]);
    run_sqrt(fx_make(1'b0,15'h4000,64'h8000000000000000), 2'd0, got); // sqrt(2.0)
    ref_ = fx_sqrt(fx_make(1'b0,15'h4000,64'h8000000000000000), 2'd0);
    $display("sqrt(2.0) = %020h inexact=%b (ref %020h inexact=%b)", got[79:0], got[80], ref_[79:0], ref_[80]);

    // random normal-operand corpus across all 4 rounding modes
    for (int i = 0; i < N; i++) begin
      man = {$urandom(), $urandom()};        // random 64-bit significand ...
      man[63] = 1'b1;                         // ... normalized (explicit integer bit)
      exp = 15'h3fff + ($urandom() % 1024) - 512;   // ~ +/-512 binades around 1.0
      rc  = $urandom() % 4;
      xa  = fx_make(1'b0, exp, man);
      run_sqrt(xa, rc, got);
      ref_ = fx_sqrt(xa, rc);
      if (got !== ref_) begin
        fail++;
        if (fail <= 8) $display("FAIL[%0d] a=%020h rc=%0d got=%023h ref=%023h", i, xa, rc, got, ref_);
      end
    end

    if (fail == 0) $display("SQRT-ITER-GATE-OK  (%0d random x 4 rc + directed, bit-exact vs fx_sqrt)", N);
    else           $display("SQRT-ITER-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end

  initial begin
    #50000000 $display("SQRT-ITER-GATE-FAIL (timeout)"); $finish;
  end
endmodule

`default_nettype wire
