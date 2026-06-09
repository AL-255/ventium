// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/trsc/tb_fpatan.sv — standalone clocked gate for fpu_fpatan vs the qref
// (qemu-bit-exact) vectors. `qref --sweep-fpatan <rc>` emits "y80 x80 out80";
// the gate splits them into fpatan_{y,x,o}.hex and passes the count + RC.
`default_nettype none

module tb_fpatan;
  import fpu_x87_pkg::*;
`ifndef FA_NV
  `define FA_NV 320
`endif
`ifndef FA_RC
  `define FA_RC 0
`endif
  localparam int NV = `FA_NV;

  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic [79:0] y='0, x='0;
  logic [1:0]  rc=2'(`FA_RC);
  logic        busy, done, ex_pe, ex_ie;
  logic [79:0] result;

  fpu_fpatan dut (.clk,.rst_n,.start,.y,.x,.rc,.busy,.done,.result,.inexact(ex_pe),.invalid(ex_ie));

  initial forever #5 clk = ~clk;

  logic [79:0] vy [0:NV-1];
  logic [79:0] vx [0:NV-1];
  logic [79:0] vo [0:NV-1];

  task automatic run_one(input logic [79:0] yy, input logic [79:0] xx, output logic [79:0] r);
    @(negedge clk); y=yy; x=xx; start=1'b1;
    @(negedge clk); start=1'b0;
    while (!done) @(negedge clk);
    r = result;
  endtask

  int fail; logic [79:0] got;
  initial begin
    $readmemh("build/trsc/fpatan_y.hex", vy);
    $readmemh("build/trsc/fpatan_x.hex", vx);
    $readmemh("build/trsc/fpatan_o.hex", vo);
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    for (int k=0;k<NV;k++) begin
      run_one(vy[k], vx[k], got);
      if (got !== vo[k]) begin
        fail++;
        if (fail<=12) $display("FAIL k=%0d y=%020h x=%020h got=%020h exp=%020h", k, vy[k], vx[k], got, vo[k]);
      end
    end
    if (fail==0) $display("FPATAN-GATE-OK  rc=%0d (%0d vectors, bit-exact vs qref/qemu)", `FA_RC, NV);
    else         $display("FPATAN-GATE-FAIL  rc=%0d (%0d / %0d mismatches)", `FA_RC, fail, NV);
    $finish;
  end

  initial begin #200000000 $display("FPATAN-GATE-FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
