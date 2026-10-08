`timescale 1ns/1ps
// Exactly the RTL scoreboard and stimuli, with time for the library GSR pulse
// and combinational primitive propagation. No DUT state is initialized/forced.
module tb_fe_banked_netlist;
  tb_fe_banked #(.SETTLE(10), .START_DELAY(200),
                 .INITIAL_PORT_TRANSITIONS(1)) testbench ();
endmodule
