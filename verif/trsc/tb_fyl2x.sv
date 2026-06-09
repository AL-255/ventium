// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Standalone clocked gate for fpu_fyl2x (FYL2X mode=0 / FYL2XP1 mode=1) vs the
// qref (qemu-bit-exact) vectors. FY_MODE/FY_RC/FY_NV selected by the gate.
`default_nettype none
module tb_fyl2x;
  import fpu_x87_pkg::*;
`ifndef FY_NV
  `define FY_NV 360
`endif
`ifndef FY_RC
  `define FY_RC 0
`endif
`ifndef FY_MODE
  `define FY_MODE 0
`endif
  localparam int NV = `FY_NV;
  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic        md=1'(`FY_MODE);
  logic [79:0] y='0, x='0;
  logic [1:0]  rc=2'(`FY_RC);
  logic        busy, done, ex_pe, ex_ie;
  logic [79:0] result;

  fpu_fyl2x dut (.clk,.rst_n,.start,.mode(md),.y,.x,.rc,.busy,.done,.result,.inexact(ex_pe),.invalid(ex_ie));
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
    $readmemh("build/trsc/fyl2x_y.hex", vy);
    $readmemh("build/trsc/fyl2x_x.hex", vx);
    $readmemh("build/trsc/fyl2x_o.hex", vo);
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    for (int k=0;k<NV;k++) begin
      run_one(vy[k], vx[k], got);
      if (got !== vo[k]) begin
        fail++;
        if (fail<=12) $display("FAIL k=%0d y=%020h x=%020h got=%020h exp=%020h", k, vy[k], vx[k], got, vo[k]);
      end
    end
    if (fail==0) $display("FYL2X-GATE-OK  mode=%0d rc=%0d (%0d vectors, bit-exact vs qref/qemu)", `FY_MODE, `FY_RC, NV);
    else         $display("FYL2X-GATE-FAIL  mode=%0d rc=%0d (%0d / %0d mismatches)", `FY_MODE, `FY_RC, fail, NV);
    $finish;
  end
  initial begin #300000000 $display("FYL2X-GATE-FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
