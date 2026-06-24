// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// feval_dut.sv — thin OOC wrapper exposing the x87 arithmetic evaluator
// ventium_x87_pkg::f_eval (the full combinational reference) AND the board's
// pipelined split f_eval_s2(f_eval_s1(...)) (the path that ships under
// +VEN_FP_PIPE2), so the standalone f_eval gate (tb_feval.cpp) can Verilate just
// the two packages + this wrapper. This hunts the UPSTREAM op that mis-feeds the
// DOS-Quake fist@0x3079a (the fist itself is bit-exact for normal integers).
//
// sub = x87 reg-field op: 0=add, 1=mul, 4=sub(a-b), 5=subr(b-a). Output is
// {ie[84], ze[83], oe[82], ue[81], pe[80], result[79:0]}.
`default_nettype none
module feval_dut
  import ventium_x87_pkg::*;
(
    input  wire logic [2:0]  sub,
    input  wire logic [79:0] a,
    input  wire logic [79:0] b,
    input  wire logic [1:0]  rc,
    input  wire logic [1:0]  pc,        // precision control (fctrl[9:8]): 00=24b 10=53b 11=64b
    input  wire logic        fdiv_err,
    output logic [84:0]      r_full,    // f_eval (full reference)
    output logic [84:0]      r_split    // f_eval_s2(f_eval_s1(...)) — the board path
);
    assign r_full  = f_eval(sub, a, b, rc, pc, fdiv_err);
    assign r_split = f_eval_s2(f_eval_s1(sub, a, b, rc, pc, fdiv_err), rc, pc);
endmodule
`default_nettype wire
