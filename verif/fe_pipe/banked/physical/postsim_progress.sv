`timescale 1ns/1ps
// Passive visibility only; all acceptance remains in tb_fe_banked.
module postsim_progress;
  initial forever begin
    #1000000;
    $display("POSTSIM-PROGRESS time=%0t checks=%0d captures=%0d",
      $time, tb_fe_banked_netlist.testbench.checks,
      tb_fe_banked_netlist.testbench.captures);
    $fflush();
  end
endmodule
