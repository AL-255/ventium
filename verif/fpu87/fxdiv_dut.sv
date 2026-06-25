// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// fxdiv_dut.sv — OOC wrapper exposing the BEHAVIORAL x87 divide fpu_x87_pkg::fx_div
// (the FDIV path of f_arith/f_eval, distinct from the iterative fpu_srt_div.sv SRT
// engine). This gates the denormal-divide path whose board-fit stub was just
// restored to the real 192-bit divide (commit 66a71c4); the denormal operands in
// gen_div_vectors.py exercise exactly that path. Combinational — no clock.
`default_nettype none
module fxdiv_dut
  import fpu_x87_pkg::*;
(
    input  wire logic [79:0] a,
    input  wire logic [79:0] b,
    input  wire logic [1:0]  rc,
    input  wire logic [1:0]  pc,
    output logic [82:0]      r       // {oe,ue,pe, 80-bit floatx80 result}
);
    assign r = fx_div(a, b, rc, pc);
endmodule
`default_nettype wire
