// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// soc/ven_fan_ctrl_top.v — plain-Verilog wrapper around ven_fan_ctrl.sv.
// Vivado's IP-Integrator `create_bd_cell -type module -reference` requires the
// reference's TOP file to be Verilog (not SystemVerilog), so this thin .v shell
// instantiates the SystemVerilog implementation for use as a BD module.
// CLK_HZ is exposed as a parameter so the BD can set it to the PL0 frequency.

module ven_fan_ctrl_top #(
    parameter CLK_HZ = 40000000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [9:0]  temp,
    input  wire        eos,
    output wire        fan_pwm
);
  ven_fan_ctrl #(.CLK_HZ(CLK_HZ)) u_fan (
      .clk(clk), .rst_n(rst_n), .temp(temp), .eos(eos), .fan_pwm(fan_pwm)
  );
endmodule
