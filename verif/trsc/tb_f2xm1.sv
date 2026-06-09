// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/trsc/tb_f2xm1.sv — standalone clocked gate for the iterative F2XM1
// engine (rtl/fpu/fpu_f2xm1.sv). Asserts the engine's floatx80 result is
// bit-exact vs the qemu-mode reference qref.c (which is itself proven equal to
// real qemu-i386, 193/193 — see tools/p5xtrans/qref_validate.py).
//
// Vectors: `qref --sweep` emits "<input80> <expected80>" per line; the gate
// splits them into f2xm1_in.hex / f2xm1_out.hex ($readmemh) and passes the
// count as +define+F2_NV. RC = 0 (round-nearest), matching qref --sweep.
// ===========================================================================
`default_nettype none

module tb_f2xm1;
  import fpu_x87_pkg::*;
`ifndef F2_NV
  `define F2_NV 256
`endif
`ifndef F2_RC
  `define F2_RC 0
`endif
  localparam int NV = `F2_NV;

  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic [79:0] x='0;
  logic [1:0]  rc=2'(`F2_RC);
  logic        busy, done;
  logic [79:0] result;

  logic ex_pe, ex_ie;
  fpu_f2xm1 dut (.clk,.rst_n,.start,.x,.rc,.busy,.done,.result,.inexact(ex_pe),.invalid(ex_ie));

  initial forever #5 clk = ~clk;

  logic [79:0] vin  [0:NV-1];
  logic [79:0] vexp [0:NV-1];

  task automatic run_one(input logic [79:0] xx, output logic [79:0] r);
    @(negedge clk); x = xx; start = 1'b1;
    @(negedge clk); start = 1'b0;
    while (!done) @(negedge clk);
    r = result;
  endtask

  int fail; logic [79:0] got;
  initial begin
    $readmemh("build/trsc/f2xm1_in.hex",  vin);
    $readmemh("build/trsc/f2xm1_out.hex", vexp);
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    for (int k=0;k<NV;k++) begin
      run_one(vin[k], got);
      if (got !== vexp[k]) begin
        fail++;
        if (fail<=12) $display("FAIL k=%0d in=%020h got=%020h exp=%020h", k, vin[k], got, vexp[k]);
      end
    end
    if (fail==0) $display("F2XM1-GATE-OK  rc=%0d (%0d vectors, bit-exact vs qref/qemu)", `F2_RC, NV);
    else         $display("F2XM1-GATE-FAIL  rc=%0d (%0d / %0d mismatches)", `F2_RC, fail, NV);
    $finish;
  end

  initial begin #50000000 $display("F2XM1-GATE-FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
