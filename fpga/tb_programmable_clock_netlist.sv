`timescale 1ns/1ps
// Post-synthesis/route clock leaf, including the optimized mailbox boundary.
module tb_programmable_clock_netlist;
    reg clk=0, resetn=0, safe=0;
    always #5 clk=~clk;
    reg [15:0] command=0;
    wire [7:0] div_lock;
    wire [5:0] flags;
    wire coreclk;
    wire [31:0] status={16'h504c,2'b01,flags[5:3],div_lock[7],flags[2:0],div_lock[6:0]};
    clock_leaf dut (.clk_in(clk),.resetn(resetn),.safe_change(safe),
        .ps_gpio_o(command),.ps_gpio_i(div_lock),.mmcm_reset_reg(flags),.clk_out(coreclk));
    integer power_writes=0;
    always @(posedge clk) begin
        if (dut.den && dut.dwe && dut.u_mmcm.DADDR==7'h27) begin
            if (dut.di !== 16'hffff) $fatal(1,"netlist disabled the DRP power group");
            power_writes <= power_writes+1;
        end
    end
    task period_check(input integer divider);
        realtime last_edge,delta;
        begin
            repeat(10) @(posedge coreclk);
            last_edge=$realtime;
            repeat(100) begin
                @(posedge coreclk); delta=$realtime-last_edge; last_edge=$realtime;
                if (delta<divider-0.01 || delta>divider+0.01)
                    $fatal(1,"netlist expected %0d ns, observed %0.3f",divider,delta);
            end
        end
    endtask
    task change(input integer divider);
        begin
            @(negedge clk); command={status[11],8'hc1,7'(divider)};
            #1000; @(negedge clk); command[15]=~command[15];
            wait(status[8]); wait(!status[8] && status[11]==command[15]);
            if (status[9] || !status[10] || !status[7] || status[6:0]!=divider)
                $fatal(1,"netlist clock change failed %h",status);
            period_check(divider);
        end
    endtask
    integer d;
    initial begin
        #1000; resetn=1;
        wait(!status[8] && status[7]); period_check(25);
        // A running guest's request must be rejected without stopping its clock.
        @(negedge clk); command={status[11],8'hc1,7'd14};
        #1000; command[15]=~command[15];
        wait(status[11]==command[15]);
        if (!status[9] || status[8] || !status[7] || status[13])
            $fatal(1,"netlist unsafe request not rejected safely");
        period_check(25);
        safe=1; #1000;
        for (d=10;d<=50;d=d+1) change(d);
        change(14);
        resetn=0; safe=0; command={1'b1,8'hc1,7'd14}; #1000; resetn=1;
        wait(!status[8] && status[7]); period_check(25);
        if (status[9]) $fatal(1,"netlist stale request replayed after reset");
        safe=1; #1000; change(25);
        if (power_writes != 90) $fatal(1,"netlist power-write count %0d",power_writes);
        $display("PROGRAMMABLE-CLOCK-NETLIST-OK: 41 dividers, power sequence, unsafe reject, reset-to40");
        $finish;
    end
    initial begin #2000000; $fatal(1,"netlist watchdog status=%h",status); end
endmodule
