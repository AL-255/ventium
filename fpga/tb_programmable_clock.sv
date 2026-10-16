`timescale 1ns/1ps
module tb_programmable_clock;
    reg clk=0, resetn=0, safe=0;
    always #5 clk=~clk;
    reg [94:0] gpio_o=0;
    wire [94:0] gpio_i;
    wire coreclk;
    wire [31:0] status={1'b0,gpio_i[94:64]};
    ven_programmable_clock dut (.clk_in(clk),.resetn(resetn),.safe_change(safe),
        .ps_gpio_o(gpio_o),.ps_gpio_i(gpio_i),.clk_out(coreclk));
    task period_check(input integer divider);
        realtime last_edge,delta;
        begin
            repeat(10) @(posedge coreclk);
            last_edge=$realtime;
            repeat(100) begin
                @(posedge coreclk); delta=$realtime-last_edge; last_edge=$realtime;
                if (delta<divider-0.01 || delta>divider+0.01)
                    $fatal(1,"expected period %0d ns, observed %0.3f",divider,delta);
            end
            $display("UNISIM clock: divider=%0d MHz=%0.6f status=%h",divider,1000.0/divider,status);
        end
    endtask
    task change(input integer divider);
        begin
            @(negedge clk); gpio_o[47:32]={status[11],8'hc1,7'(divider)};
            #1000; @(negedge clk); gpio_o[47]=~gpio_o[47];
            wait(status[8]); wait(!status[8] && status[11]==gpio_o[47]);
            if (status[9] || !status[10] || !status[7] || status[6:0]!=divider)
                $fatal(1,"clock change failed %h",status);
            period_check(divider);
        end
    endtask
    integer d;
    initial begin
        #1000; resetn=1;
        wait(!status[8] && status[7]); period_check(25);
        safe=1; #1000;
        // Every supported odd/even divisor, not just integer MHz points.
        for (d=10;d<=50;d=d+1) change(d);
        change(14);
        resetn=0; safe=0;
        gpio_o[47:32]={1'b1,8'hc1,7'd14}; #1000; resetn=1;
        wait(!status[8] && status[7]); period_check(25);
        if (status[9]) $fatal(1,"stale request was replayed after reset");
        safe=1; #1000;
        change(25);
        $display("PROGRAMMABLE-CLOCK-UNISIM-OK"); $finish;
    end
    initial begin #2000000; $fatal(1,"UNISIM watchdog status=%h",status); end
endmodule
