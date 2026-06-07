// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/fppipe/tb_fppipe.sv — standalone COMBINATIONAL gate for the 2-stage FP
// arithmetic split (for +VEN_FP_PIPE). Asserts
//     f_eval_s2(f_eval_s1(sub,a,b,rc,err), rc)  ==  f_eval(sub,a,b,rc,err)
// bit-exact for the add/sub/mul groups (sub 0/1/4/5 — the only groups the
// pipelined fast arm splits; divides are SRT-engine-routed) over random
// floatx80 operands spanning normals / signed zeros / Inf / QNaN / SNaN and all
// four rounding modes. This proves the datapath split is exact BEFORE any FSM
// surgery. No clock — pure function composition.
// ===========================================================================
`default_nettype none

module tb_fppipe;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
`ifndef FPPIPE_N
  `define FPPIPE_N 1000000
`endif
  localparam int N = `FPPIPE_N;

  function automatic logic [79:0] rnd_op();
    logic [63:0] man; logic [14:0] exp; logic sg; int kind;
    kind = $urandom() % 16;
    sg   = $urandom() & 1;
    man  = {$urandom(), $urandom()};
    case (kind)
      0, 1:    begin exp = 15'd0;     man = 64'd0; end                       // signed zero
      2:       begin exp = 15'h7fff;  man = 64'h8000000000000000; end        // Inf
      3:       begin exp = 15'h7fff;  man = {2'b11, man[61:0]}; end           // QNaN
      4:       begin exp = 15'h7fff;  man = {2'b10, man[61:1], 1'b1}; end     // SNaN
      default: begin                                                          // normal
        man[63] = 1'b1;                                                       // integer bit
        exp = 15'($signed(15'h3fff) + ($signed({1'b0,man[7:0]}) % 200) - 100);
      end
    endcase
    return fx_make(sg, exp, man);
  endfunction

  int fail, k, idx;
  logic [2:0] s;
  logic [1:0] rc;
  logic [79:0] a, b;
  logic [82:0] ref_, got;
  fx_pipe_t p;
  logic [2:0] subs [4];

  task automatic chk(input logic [2:0] sub, input logic [79:0] aa, input logic [79:0] bb,
                     input logic [1:0] rcc);
    logic [82:0] rf, gt; fx_pipe_t pp;
    rf = f_eval(sub, aa, bb, rcc, 1'b0);
    pp = f_eval_s1(sub, aa, bb, rcc, 1'b0);
    gt = f_eval_s2(pp, rcc);
    if (gt !== rf) begin
      fail++;
      if (fail<=12) $display("FAIL sub=%0d rc=%0d a=%020h b=%020h ref=%021h got=%021h",
                             sub, rcc, aa, bb, rf, gt);
    end
  endtask

  initial begin
    subs[0]=3'd0; subs[1]=3'd1; subs[2]=3'd4; subs[3]=3'd5;
    fail=0;
    // directed sanity
    chk(3'd0, fx_make(1'b0,15'h3fff,64'h8000000000000000),
              fx_make(1'b0,15'h3fff,64'h8000000000000000), 2'd0);          // 1+1
    chk(3'd1, fx_make(1'b0,15'h4000,64'h8000000000000000),
              fx_make(1'b0,15'h4000,64'hC000000000000000), 2'd0);          // 2*3
    chk(3'd4, fx_make(1'b0,15'h3fff,64'h8000000000000000),
              fx_make(1'b0,15'h3fff,64'h8000000000000000), 2'd1);          // 1-1 (cancel, RC-down)
    // random corpus
    for (k=0; k<N; k++) begin
      a   = rnd_op();
      b   = rnd_op();
      rc  = 2'($urandom());
      idx = $urandom() % 4;
      s   = subs[idx];
      chk(s, a, b, rc);
    end
    if (fail==0) $display("FPPIPE-GATE-OK  (%0d random + directed, f_eval_s2(f_eval_s1)==f_eval for add/sub/mul)", N);
    else         $display("FPPIPE-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end
endmodule

`default_nettype wire
