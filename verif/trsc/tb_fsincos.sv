// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Standalone clocked gate for fpu_fsincos (FSIN op=0 / FCOS op=1) vs the qref
// shared-poly model vectors. Bit-exact (both use floatx80 RNE ops).
`default_nettype none
module tb_fsincos;
  import fpu_x87_pkg::*;
`ifndef FS_NV
  `define FS_NV 4096
`endif
`ifndef FS_OP
  `define FS_OP 0
`endif
  localparam int NV = `FS_NV;
  logic        clk=1'b0, rst_n=1'b0, start=1'b0;
  logic [79:0] x='0;
  logic        busy, done, c2;
  logic [79:0] sin_o, cos_o;

  fpu_fsincos dut (.clk,.rst_n,.start,.x,.busy,.done,.sin_o,.cos_o,.c2_o(c2));
  initial forever #5 clk = ~clk;

  logic [79:0] vx [0:NV-1];
  logic [79:0] vo [0:NV-1];

  task automatic run_one(input logic [79:0] xx, output logic [79:0] r);
    @(negedge clk); x=xx; start=1'b1;
    @(negedge clk); start=1'b0;
    while (!done) @(negedge clk);
    r = (`FS_OP) ? cos_o : sin_o;
  endtask

  int fail; logic [79:0] got;
  initial begin
    $readmemh("build/trsc/fsincos_x.hex", vx);
    $readmemh("build/trsc/fsincos_o.hex", vo);
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    for (int k=0;k<NV;k++) begin
      run_one(vx[k], got);
      if (got !== vo[k]) begin
        fail++;
        if (fail<=12) $display("FAIL k=%0d x=%020h got=%020h exp=%020h", k, vx[k], got, vo[k]);
      end
    end
    if (fail==0) $display("FSINCOS-GATE-OK  op=%0d (%0d vectors, bit-exact vs qref model)", `FS_OP, NV);
    else         $display("FSINCOS-GATE-FAIL  op=%0d (%0d / %0d mismatches)", `FS_OP, fail, NV);
    $finish;
  end
  initial begin #500000000 $display("FSINCOS-GATE-FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
