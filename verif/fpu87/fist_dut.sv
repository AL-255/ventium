// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// fist_dut.sv — thin OOC wrapper exposing fpu_x87_pkg::fx_to_int_ex (the x87
// FIST/FISTP floatx80->signed-integer conversion) as a purely combinational
// module, so the standalone fist gate (tb_fist.cpp) can Verilate just the
// package + this wrapper (tiny, low memory) instead of the whole core.
`default_nettype none
module fist_dut
  import fpu_x87_pkg::*;
(
    input  wire logic [79:0] v,        // floatx80 source (ST0)
    input  wire logic [7:0]  width,    // destination width in bits: 16 / 32 / 64
    input  wire logic [1:0]  rc,       // x87 rounding control
    output logic [65:0]      r         // {invalid, inexact, value[63:0]}
);
    assign r = fx_to_int_ex(v, int'(width), rc);
endmodule
`default_nettype wire
