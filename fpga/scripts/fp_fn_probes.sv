// fpga/scripts/fp_fn_probes.sv — standalone area probes for the x87 FP datapath
// functions (fpu_x87_pkg). Each wrapper registers inputs and outputs around one
// function call so OOC synth measures that function's PURE COMBINATIONAL cone
// (LUT/CARRY8/DSP), isolating which FP op dominates the ~58K "u_fpu_state"
// flatten-attributed cone. NOT part of any build — measurement only.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

`default_nettype none

module probe_fx_add import fpu_x87_pkg::*; (
    input  wire logic        clk,
    input  wire logic [79:0] a_i, b_i,
    input  wire logic [1:0]  rc_i,
    output logic [80:0]      y_o
);
  logic [79:0] a_q, b_q; logic [1:0] rc_q; logic [80:0] y;
  always_ff @(posedge clk) begin a_q<=a_i; b_q<=b_i; rc_q<=rc_i; y_o<=y; end
  assign y = fx_add(a_q, b_q, rc_q);
endmodule

module probe_fx_mul import fpu_x87_pkg::*; (
    input  wire logic        clk,
    input  wire logic [79:0] a_i, b_i,
    input  wire logic [1:0]  rc_i,
    output logic [80:0]      y_o
);
  logic [79:0] a_q, b_q; logic [1:0] rc_q; logic [80:0] y;
  always_ff @(posedge clk) begin a_q<=a_i; b_q<=b_i; rc_q<=rc_i; y_o<=y; end
  assign y = fx_mul(a_q, b_q, rc_q);
endmodule

module probe_fx_round import fpu_x87_pkg::*; (
    input  wire logic        clk,
    input  wire logic        sign_i,
    input  wire logic signed [31:0] unb_i,
    input  wire logic [127:0] sig_i,
    input  wire logic        pinx_i,
    input  wire logic [1:0]  rc_i,
    output logic [80:0]      y_o
);
  logic s_q, p_q; logic signed [31:0] u_q; logic [127:0] g_q; logic [1:0] rc_q; logic [80:0] y;
  always_ff @(posedge clk) begin s_q<=sign_i; u_q<=unb_i; g_q<=sig_i; p_q<=pinx_i; rc_q<=rc_i; y_o<=y; end
  assign y = fx_round_pack(s_q, u_q, g_q, p_q, rc_q);
endmodule

module probe_fx_toint import fpu_x87_pkg::*; (
    input  wire logic        clk,
    input  wire logic [79:0] v_i,
    input  wire logic [1:0]  rc_i,
    output logic [65:0]      y_o
);
  logic [79:0] v_q; logic [1:0] rc_q; logic [65:0] y;
  always_ff @(posedge clk) begin v_q<=v_i; rc_q<=rc_i; y_o<=y; end
  assign y = fx_to_int_ex(v_q, 64, rc_q);
endmodule

module probe_fx_bcdtofx import fpu_x87_pkg::*; (
    input  wire logic        clk,
    input  wire logic [79:0] bcd_i,
    output logic [79:0]      y_o
);
  logic [79:0] b_q; logic [79:0] y;
  always_ff @(posedge clk) begin b_q<=bcd_i; y_o<=y; end
  assign y = fx_bcd_to_fx(b_q);
endmodule

`default_nettype wire
