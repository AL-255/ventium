`timescale 1ns/1ps
// Public pin/ready contract of the FPGA's actual transmit-only keyboard device.
// No controller/register/FIFO substitution or internal state access.
module tb_kbd_inhibit;
    parameter integer HZ=40000000;
    localparam integer HALF=(64'd128*HZ+3124999)/3125000;
    localparam integer CELL=2*HALF;
    localparam integer IDLE=(64'd80*HZ+3124999)/3125000;
    reg clk=0,rst_n=0,valid=0,hc=1,hd=1;
    reg [7:0] data=0;
    wire ready,busy,dc,dd;
    integer phase,bit_number,i,n,initial_edges,edges=0;
    always #5 clk=~clk;
    always @(negedge dc) if(hc && rst_n) edges=edges+1;
    ven_ps2_kbd_inject #(.CLK_HZ(HZ)) dut (
        .clk(clk),.rst_n(rst_n),.inject_valid(valid),.inject_data(data),
        .inject_ready(ready),.inject_busy(busy),
        .host_clk_release(hc),.host_dat_release(hd),
        .dev_clk_release(dc),.dev_dat_release(dd));
    task queue(input [7:0] value);
        begin
            if (!ready || busy) $fatal(1,"queue without credit");
            @(negedge clk);data=value;valid=1;
            @(negedge clk);valid=0;
            if (ready || !busy) $fatal(1,"byte not owned");
        end
    endtask
    task wire_byte(input [7:0] value);
        reg [10:0] expected;
        integer j;
        begin
            expected={1'b1,~^value,value,1'b0};
            for(j=0;j<11;j=j+1) begin
                @(negedge dc);
                if(!hc || dd !== expected[j])
                    $fatal(1,"retry/frame mismatch bit=%0d got=%b expected=%b",j,dd,expected[j]);
                @(posedge dc);
            end
            repeat(3) @(negedge clk);
            if(!ready || busy) $fatal(1,"completed frame still owned");
        end
    endtask
    initial begin
        if(!$value$plusargs("phase=%d",phase) || phase<0 || phase>22)
            $fatal(1,"phase selector required");
        repeat(8) @(negedge clk);rst_n=1;
        queue(8'h5a);@(negedge dd);
        bit_number=phase/2;
        for(i=0;i<bit_number;i=i+1) begin @(negedge dc);@(posedge dc);end
        if(phase<22) begin
            if(phase%2) @(negedge dc);
            repeat(HALF/2) @(negedge clk);
        end else repeat(IDLE+32) @(negedge clk);
        initial_edges=edges;
        if(initial_edges !== bit_number+(phase%2)) $fatal(1,"wrong physical phase");
        @(negedge clk);hc=0;
        for(n=0;n<12*CELL+IDLE+16;n=n+1) begin
            @(negedge clk);
            if(phase<21 && (ready || !busy))
                $fatal(1,"KBD-EARLY-READY-WHILE-INHIBITED hz=%0d phase=%0d edges=%0d",HZ,phase,edges);
        end
        if(dc !== 1 || dd !== 1) $fatal(1,"inhibit did not release device pins");
        if(phase>=21 && (!ready || busy)) $fatal(1,"completed stop was retried");
        @(negedge clk);hc=1;
        if(phase<21) begin
            wire_byte(8'h5a);
            if(edges != initial_edges+11) $fatal(1,"retry was not exactly one whole frame");
        end else begin
            repeat(IDLE+12*CELL) @(negedge clk);
            if(edges != initial_edges || !ready) $fatal(1,"duplicate after completed stop");
        end
        queue(8'ha5);wire_byte(8'ha5);
        // Guest reset cancels the retained old byte; no automatic old-guest retry.
        queue(8'h33);repeat(3) @(negedge dc);
        @(negedge clk);rst_n=0;
        repeat(8) @(negedge clk);
        if(!ready || busy || dc !== 1 || dd !== 1) $fatal(1,"reset retained a byte");
        initial_edges=edges;rst_n=1;
        repeat(IDLE+12*CELL) @(negedge clk);
        if(edges!=initial_edges) $fatal(1,"old byte replayed after reset");
        $display("KBD-INHIBIT-OK hz=%0d phase=%0d retry=%0d reset_cancel=1",HZ,phase,phase<21);
        $finish;
    end
    // At 40 MHz, completed-stop controls include two full inhibited/idle
    // observation windows, a fresh frame and reset cancellation (>200k clocks).
    initial begin repeat(300000) @(posedge clk);$fatal(1,"bounded keyboard inhibit timeout");end
endmodule
