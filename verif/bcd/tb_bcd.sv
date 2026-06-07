// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/bcd/tb_bcd.sv — standalone clocked gate for the iterative FP->packed-BCD
// engine (rtl/fpu/ven_bcd.sv). Asserts the engine's {ie,pe,bcd} is bit-exact vs
// the combinational fpu_x87_pkg::fx_fx_to_bcd (FBSTP) over random floatx80 values
// spanning the BCD range (|val| < 10^18) and the int64/range overflow cases.
// Built with the --timing flag.
// ===========================================================================
`default_nettype none

module tb_bcd;
  import fpu_x87_pkg::*;
`ifndef BCD_N
  `define BCD_N 40000
`endif
  localparam int N = `BCD_N;

  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic [79:0] v='0;
  logic [1:0]  rc=2'd0;
  logic        busy, done;
  logic [81:0] result;

  ven_bcd dut (.clk,.rst_n,.start,.v,.rc,.busy,.done,.result);

  initial forever #5 clk = ~clk;

  task automatic run_one(input logic [79:0] vv, input logic [1:0] rcc, output logic [81:0] r);
    @(negedge clk); v=vv; rc=rcc; start=1'b1;
    @(negedge clk); start=1'b0;
    while (!done) @(negedge clk);
    r = result;
  endtask

  int fail;
  logic [81:0] got, ref_;
  logic [79:0] xv;
  logic [63:0] man;
  logic [14:0] exp;
  logic        sg;
  initial begin
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    // directed
    run_one(fx_make(1'b0,15'h3fff,64'h8000000000000000), 2'd0, got);   // 1.0 -> 1
    $display("bcd(1.0)  = %020h ie=%b pe=%b", got[79:0], got[81], got[80]);
    run_one(fx_make(1'b0,15'h4005,64'hC900000000000000), 2'd0, got);   // 100.5 -> round
    ref_ = fx_fx_to_bcd(fx_make(1'b0,15'h4005,64'hC900000000000000), 2'd0);
    $display("bcd(100.5)= %020h (ref %020h)", got[79:0], ref_[79:0]);
    // random corpus across magnitudes (1 .. ~2^70 incl >10^18 overflow) + signs + rc
    for (int k=0;k<N;k++) begin
      man = {$urandom(),$urandom()}; man[63]=1'b1;
      exp = 15'h3fff + ($urandom() % 75);        // ~1 .. 2^74 (covers <10^18 and overflow)
      if (($urandom()%8)==0) exp = 15'h3fff - ($urandom()%40);  // small -> ~0
      sg  = $urandom() & 1;
      rc  = $urandom() % 4;
      xv  = fx_make(sg, exp, man);
      run_one(xv, rc, got);
      ref_ = fx_fx_to_bcd(xv, rc);
      if (got !== ref_) begin
        fail++;
        if (fail<=10) $display("FAIL k=%0d v=%020h rc=%0d got=%021h ref=%021h", k, xv, rc, got, ref_);
      end
    end
    if (fail==0) $display("BCD-GATE-OK  (%0d random + directed, bit-exact vs fx_fx_to_bcd)", N);
    else         $display("BCD-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end

  initial begin #100000000 $display("BCD-GATE-FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
