`timescale 1ns/1ps
module tb_pll_ctrl;
    reg clk=0, resetn=0, safe=0, locked=0;
    always #5 clk=~clk;
    reg [15:0] command=0, dout=0;
    reg drdy=0;
    wire [31:0] status;
    wire rst, ce, den, dwe;
    wire [6:0] addr;
    wire [15:0] di;
    ven_pll_ctrl #(.TIMEOUT_BITS(10), .GUARD_CYCLES(8)) dut (
        .clk(clk), .resetn(resetn), .command_async(command),
        .safe_change_async(safe), .locked(locked), .status(status),
        .mmcm_reset(rst), .clock_enable(ce), .daddr(addr), .di(di),
        .den(den), .dwe(dwe), .dout(dout), .drdy(drdy));
    reg [15:0] r08=16'hb30d, r09=16'h0285;
    reg [15:0] r27=16'h0100;
    reg drop_drp=0, drop_lock=0, corrupt08=0, corrupt09=0;
    reg corrupt_power_on=0, corrupt_power_final=0;
    integer latency=4, wait_drp=0, lock_wait=0, accesses=0, writes=0, divider_writes=0;
    reg [6:0] pending_addr;
    reg pending_write, pending_power_final;
    reg [15:0] pending_data;
    always @(posedge clk) begin
        drdy <= 0;
        if (rst || drop_lock) begin locked <= 0; lock_wait <= 0; end
        else if (lock_wait == 12) locked <= 1;
        else lock_wait <= lock_wait+1;
        if (!resetn) begin wait_drp <= 0; drdy <= 0; end
        else begin
            if (den) begin
                if (wait_drp || drdy) $fatal(1,"overlapping DRP request");
                if (!rst || ce) $fatal(1,"DRP without gated/reset MMCM");
                if (addr!=8 && addr!=9 && addr!=7'h27) $fatal(1,"unexpected DRP address");
                if (addr!=7'h27 && (r27 & 16'h9999)!=16'h9999)
                    $fatal(1,"divider access without enabled DRP power group");
                if (addr==7'h27 && dwe && di!=16'hffff)
                    $fatal(1,"power group must remain enabled through relock");
                accesses <= accesses+1;
                pending_addr <= addr; pending_write <= dwe; pending_data <= di;
                pending_power_final <= dut.state==13;
                if (!drop_drp) wait_drp <= latency;
            end
            if (wait_drp > 1) wait_drp <= wait_drp-1;
            if (wait_drp == 1) begin
                wait_drp <= 0; drdy <= 1;
                if (pending_write) begin
                    writes <= writes+1;
                    if (pending_addr!=7'h27) divider_writes <= divider_writes+1;
                    if (pending_addr==8) r08 <= pending_data ^ (corrupt08 ? 16'd1 : 16'd0);
                    else if (pending_addr==9) r09 <= pending_data ^ (corrupt09 ? 16'd1 : 16'd0);
                    else r27 <= pending_data ^ (((!pending_power_final && corrupt_power_on) ||
                                                  (pending_power_final && corrupt_power_final)) ? 16'd1 : 16'd0);
                end else dout <= pending_addr==8 ? r08 : pending_addr==9 ? r09 : r27;
            end
        end
    end
    task ticks(input integer n);
        repeat(n) begin @(posedge clk); #1; end
    endtask
    task send(input integer div);
        // Bundled data precedes request, including after rejected commands.
        @(negedge clk); command={status[11],8'hc1,7'(div)};
        ticks(5); @(negedge clk); command[15]=~command[15];
    endtask
    task finish_command(input bit expected_error);
        integer n;
        begin
            n=0;
            while ((status[11] != command[15] || status[8]) && n<1600) begin ticks(1); n=n+1; end
            if (n==1600 || status[9]!==expected_error) $fatal(1,"ack/error: %h state %d",status,dut.state);
            if (!expected_error && (!ce || rst || !locked || r27!=16'hffff)) $fatal(1,"successful clock/power state invalid");
        end
    endtask
    task set_div(input integer div);
        reg [15:0] save08,save09;
        integer before_writes;
        begin
            save08=r08; save09=r09; before_writes=writes;
            send(div); finish_command(0);
            if (status[6:0]!=div || r08[11:6]!=div/2 || r08[5:0]!=div-div/2 || r09[7]!=(div%2) || r09[6])
                $fatal(1,"divider encoding %d: %h %h",div,r08,r09);
            if (r08[15:12]!=save08[15:12] || (r09 & 16'hff3f)!=(save09 & 16'hff3f))
                $fatal(1,"unrelated DRP bits modified");
            ticks(40);
            if (writes!=before_writes+4) $fatal(1,"duplicate/missing transaction");
        end
    endtask
    integer d, s, before_accesses;
    initial begin
        ticks(5); resetn=1; ticks(160);
        if (!ce || status[6:0]!=25 || status[31:14]!=18'h14131) $fatal(1,"startup status %h",status);
        before_accesses=accesses;
        send(20); finish_command(1); // running guest: must reject, not gate.
        if (!ce || rst || accesses!=before_accesses) $fatal(1,"unsafe request stopped running clock");
        safe=1; ticks(40);
        for (d=10; d<=50; d=d+1) begin latency=2+(d%17); set_div(d); end
        set_div(25);
        send(9); finish_command(1); if (!ce) $fatal(1,"invalid divider gated clock");
        send(51); finish_command(1); if (!ce) $fatal(1,"invalid divider gated clock");
        before_accesses=accesses;
        command={~status[11],8'h00,7'd20}; ticks(40);
        if (accesses!=before_accesses || !ce) $fatal(1,"bad magic accepted");
        command[15]=status[11]; ticks(5);
        drop_drp=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"timeout not fail closed");
        drop_drp=0; set_div(25);
        corrupt08=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"readback08 not fail closed");
        corrupt08=0; set_div(25);
        corrupt09=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"readback09 not fail closed");
        corrupt09=0; set_div(25);
        drop_lock=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"lock timeout not fail closed");
        drop_lock=0; set_div(25);
        // Lose the hardware interlock in EVERY change phase, including relock.
        for (s=2; s<=14; s=s+1) begin
            latency=20; send(20); wait(dut.state==s); @(negedge clk); safe=0;
            finish_command(1);
            if (ce || !rst) $fatal(1,"safe loss state %d not fail closed",s);
            ticks(30); safe=1; ticks(40); set_div(25);
        end
        // An unsupported fractional/CDDC initial state must not be overwritten.
        r09=r09|16'h0800; before_accesses=divider_writes; send(20); finish_command(1);
        if (divider_writes!=before_accesses || ce || !rst) $fatal(1,"fractional state not rejected");
        r09=r09 & 16'hf7ff; set_div(25);
        r09=r09|16'h8000; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"CDDC state not rejected");
        r09=r09 & 16'h7fff; set_div(25);
        corrupt_power_on=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"power-enable readback error not fail closed");
        corrupt_power_on=0; set_div(25);
        corrupt_power_final=1; send(20); finish_command(1);
        if (ce || !rst) $fatal(1,"final power readback error not fail closed");
        corrupt_power_final=0; set_div(25);
        set_div(20);
        @(negedge clk); resetn=0; command=0;
        ticks(5); resetn=1; ticks(400);
        if (!ce || status[6:0]!=25 || r08[11:6]!=12 || r08[5:0]!=13 || !r09[7])
            $fatal(1,"reset did not restore 40 MHz divider");
        for (s=2;s<=14;s=s+1) begin
            send(20); wait(dut.state==s); @(negedge clk); resetn=0; command=0;
            ticks(5); resetn=1; ticks(400);
            if (!ce || status[6:0]!=25 || r08[11:6]!=12 || r08[5:0]!=13 || !r09[7])
                $fatal(1,"reset during phase %d did not recover 40 MHz",s);
        end
        $display("PLL-CTRL-OK: 41 dividers, rejection, DRP/lock timeout, readback, safe-loss all phases, recovery");
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
