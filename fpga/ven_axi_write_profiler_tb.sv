`timescale 1ns/1ps

// Focused timing-contract regression for ven_axi_write_profiler.  It covers
// decoupled AW/W acceptance, B-response delay, re-arming, and a non-OKAY B.
module ven_axi_write_profiler_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg aw_handshake = 1'b0;
    reg wlast_handshake = 1'b0;
    reg b_handshake = 1'b0;
    reg [1:0] bresp = 2'b00;
    wire [31:0] busy_cycles, bwait_cycles, bresp_error_count;

    ven_axi_write_profiler dut (
        .clk(clk), .rst(rst), .aw_handshake(aw_handshake),
        .wlast_handshake(wlast_handshake), .b_handshake(b_handshake),
        .bresp(bresp), .busy_cycles(busy_cycles), .bwait_cycles(bwait_cycles),
        .bresp_error_count(bresp_error_count)
    );

    task automatic tick(input aw, input wl, input b, input [1:0] resp);
        begin
            @(negedge clk);
            aw_handshake = aw;
            wlast_handshake = wl;
            b_handshake = b;
            bresp = resp;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        tick(0, 0, 0, 2'b00);
        rst = 1'b0;

        // AW arrives first.  WLAST arrives three cycles later and B four
        // cycles after that: total observed active=7, B-wait=4.
        tick(1, 0, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(0, 1, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(0, 0, 1, 2'b00);
        if (busy_cycles !== 32'd7 || bwait_cycles !== 32'd4 ||
            bresp_error_count !== 32'd0) begin
            $display("WRITE-PROFILER FAIL skewed write busy=%0d bwait=%0d err=%0d",
                     busy_cycles, bwait_cycles, bresp_error_count);
            $fatal;
        end

        // A simultaneous AW/WLAST followed immediately by B takes one active
        // response cycle.  Make it SLVERR to verify passive error accounting.
        tick(1, 1, 0, 2'b00);
        tick(0, 0, 1, 2'b10);
        if (busy_cycles !== 32'd8 || bwait_cycles !== 32'd5 ||
            bresp_error_count !== 32'd1) begin
            $display("WRITE-PROFILER FAIL rearm busy=%0d bwait=%0d err=%0d",
                     busy_cycles, bwait_cycles, bresp_error_count);
            $fatal;
        end

        // AXI permits W-before-AW.  It must not be misclassified as a response
        // wait until the missing address channel is accepted.
        tick(0, 1, 0, 2'b00);
        tick(0, 0, 0, 2'b00);
        tick(1, 0, 0, 2'b00);
        tick(0, 0, 1, 2'b00);
        if (busy_cycles !== 32'd11 || bwait_cycles !== 32'd6 ||
            bresp_error_count !== 32'd1) begin
            $display("WRITE-PROFILER FAIL W-before-AW busy=%0d bwait=%0d err=%0d",
                     busy_cycles, bwait_cycles, bresp_error_count);
            $fatal;
        end

        $display("VEN-AXI-WRITE-PROFILER-TB-OK");
        $finish;
    end
endmodule
