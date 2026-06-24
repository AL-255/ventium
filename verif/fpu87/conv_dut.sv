// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// conv_dut.sv — OOC wrapper exposing the x87 float32/float64 <-> floatx80
// conversions (FLD/FST m32/m64) for the standalone conversion gate (tb_conv.cpp).
// fx_from_f32/f64 are exact widening; fx_to_f32_ex/f64_ex are narrowing-with-
// rounding (the fist-like suspects for the Quake fist-input divergence).
`default_nettype none
module conv_dut
  import fpu_x87_pkg::*;
(
    input  wire logic [31:0] u32,
    input  wire logic [63:0] u64,
    input  wire logic [79:0] v,
    input  wire logic [1:0]  rc,
    output logic [79:0]      o_from32,   // fx_from_f32(u32)
    output logic [79:0]      o_from64,   // fx_from_f64(u64)
    output logic [34:0]      o_to32,     // {oe,ue,pe, f32}
    output logic [66:0]      o_to64      // {oe,ue,pe, f64}
);
    assign o_from32 = fx_from_f32(u32);
    assign o_from64 = fx_from_f64(u64);
    assign o_to32   = fx_to_f32_ex(v, rc);
    assign o_to64   = fx_to_f64_ex(v, rc);
endmodule
`default_nettype wire
