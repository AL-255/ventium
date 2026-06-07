// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/srt/tb_srt_iter.sv — standalone clocked gate for the ITERATIVE radix-4
// SRT divider (rtl/fpu/fpu_srt_div.sv). Drives the SAME golden vectors as the
// combinational gate (tb_srt.sv) through the multi-cycle engine and asserts the
// committed floatx80 is bit-exact for BOTH the correct PLA (== fx_srt_div ==
// srt_model.py == QEMU) and the buggy PLA (the Pentium FDIV flaw). Proves the
// iterative engine is equivalent to the proven combinational fx_srt_div.
// Requires Verilator --timing (delays + event control).
// ===========================================================================
`default_nettype none

module tb_srt_iter;
  import fpu_x87_pkg::*;
`ifndef SRT_N
  `define SRT_N 609
`endif
  localparam int N = `SRT_N;
  logic [79:0] av [N], bv [N], ec [N], eb [N];

  logic        clk = 1'b0, rst_n = 1'b0, start = 1'b0, buggy = 1'b0;
  logic [79:0] a = '0, b = '0;
  logic [1:0]  rc = 2'd0;
  logic        busy, done;
  logic [80:0] result;

  fpu_srt_div dut (.clk, .rst_n, .start, .a, .b, .rc, .buggy, .busy, .done, .result);

  initial forever #5 clk = ~clk;

  // run one divide to completion; return the committed significand+exp (80-bit)
  task automatic run_div(input logic [79:0] da, input logic [79:0] db,
                         input logic bug, output logic [79:0] r);
    @(negedge clk);
    a = da; b = db; buggy = bug; rc = 2'd0; start = 1'b1;
    @(negedge clk); start = 1'b0;
    while (!done) @(negedge clk);
    r = result[79:0];
  endtask

  int          fail, maxcyc, cyc;
  logic [79:0] gotc, gotb, hc0, hb0;
  initial begin
    $readmemh("build/srt/vec_a.hex",  av);
    $readmemh("build/srt/vec_b.hex",  bv);
    $readmemh("build/srt/vec_ec.hex", ec);
    $readmemh("build/srt/vec_eb.hex", eb);
    rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1; @(negedge clk);

    fail = 0; maxcyc = 0;
    for (int i = 0; i < N; i++) begin
      run_div(av[i], bv[i], 1'b0, gotc);
      run_div(av[i], bv[i], 1'b1, gotb);
      if (i == 0) begin hc0 = gotc; hb0 = gotb; end
      if (gotc !== ec[i]) begin
        fail++; if (fail<=8) $display("FAIL[%0d] correct: a=%020h b=%020h got=%020h exp=%020h", i, av[i], bv[i], gotc, ec[i]);
      end
      if (gotb !== eb[i]) begin
        fail++; if (fail<=8) $display("FAIL[%0d] buggy:   a=%020h b=%020h got=%020h exp=%020h", i, av[i], bv[i], gotb, eb[i]);
      end
    end

    // headline: the famous FDIV pair, both PLAs, through the iterative engine
    $display("ITER FDIV 4195835/3145727 correct = %020h (expect 3fffaabaa0e3e35a14bd)", hc0);
    $display("ITER FDIV 4195835/3145727 flawed  = %020h (expect 3fffaab7f6392a768638)", hb0);
    if (fail == 0) $display("SRT-ITER-GATE-OK  (%0d vectors x 2 PLAs bit-exact vs golden, iterative engine)", N);
    else           $display("SRT-ITER-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end

  // watchdog: a divide must complete well within ~50 clocks
  initial begin
    #500000 $display("SRT-ITER-GATE-FAIL (timeout)"); $finish;
  end
endmodule

`default_nettype wire
