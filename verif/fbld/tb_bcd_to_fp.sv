// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/fbld/tb_bcd_to_fp.sv — standalone clocked gate for the iterative
// packed-BCD -> floatx80 engine (rtl/fpu/ven_bcd_to_fp.sv, FBLD). Asserts the
// engine's floatx80 result is bit-exact vs the combinational fx_bcd_to_fx over
// random valid packed-BCD (18 digits 0..9 + sign) + directed values.
// ===========================================================================
`default_nettype none

module tb_bcd_to_fp;
  import fpu_x87_pkg::*;
`ifndef FBLD_N
  `define FBLD_N 40000
`endif
  localparam int N = `FBLD_N;

  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic [79:0] bcd='0;
  logic        busy, done;
  logic [79:0] result;

  ven_bcd_to_fp dut (.clk,.rst_n,.start,.bcd,.busy,.done,.result);

  initial forever #5 clk = ~clk;

  task automatic run_one(input logic [79:0] bb, output logic [79:0] r);
    @(negedge clk); bcd=bb; start=1'b1;
    @(negedge clk); start=1'b0;
    while (!done) @(negedge clk);
    r = result;
  endtask

  function automatic logic [79:0] rnd_bcd();
    logic [79:0] b; b = 80'd0;
    for (int d=0; d<18; d++) b[d*4 +: 4] = ($urandom() % 10);   // each digit 0..9
    b[79] = $urandom() & 1;                                     // sign
    return b;
  endfunction

  int fail; logic [79:0] got, ref_, xb;
  initial begin
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    // directed: 0, 1, 99..9 (18 nines), negative
    run_one(80'd0, got);
    ref_ = fx_bcd_to_fx(80'd0);
    if (got!==ref_) begin fail++; $display("FAIL bcd=0 got=%020h ref=%020h", got, ref_); end
    begin logic [79:0] one=80'd0; one[3:0]=4'd1; run_one(one, got);
      ref_=fx_bcd_to_fx(one);
      $display("fbld(1) = %020h (ref %020h)", got, ref_);
      if (got!==ref_) fail++; end
    // random corpus
    for (int k=0;k<N;k++) begin
      xb  = rnd_bcd();
      run_one(xb, got);
      ref_ = fx_bcd_to_fx(xb);
      if (got !== ref_) begin
        fail++;
        if (fail<=10) $display("FAIL k=%0d bcd=%020h got=%020h ref=%020h", k, xb, got, ref_);
      end
    end
    if (fail==0) $display("FBLD-GATE-OK  (%0d random + directed, bit-exact vs fx_bcd_to_fx)", N);
    else         $display("FBLD-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end

  initial begin #100000000 $display("FBLD-GATE-FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
