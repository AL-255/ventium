// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// fcom_dut.sv — OOC wrapper exposing ventium_x87_pkg::fcom_codes (the x87
// FCOM/FUCOM condition codes {C3,C2,C0}) for the standalone FCOM gate
// (tb_fcom.cpp). A wrong compare -> wrong branch -> wrong loop count is the
// strongest remaining suspect for the DOS-Quake fist-input divergence ("2 extra
// iterations" => the loop bound was computed/compared wrong, not mis-converted).
`default_nettype none
module fcom_dut
  import ventium_x87_pkg::*;
(
    input  wire logic [79:0] a,
    input  wire logic [79:0] b,
    output logic [2:0]       codes      // {C3, C2, C0}: less=001 equal=100 greater=000 unordered=111
);
    assign codes = fcom_codes(a, b);
endmodule
`default_nettype wire
