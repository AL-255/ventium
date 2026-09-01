`timescale 1ns/1ps

// Focused timing-contract regression for ven_axi_read_profiler.  The first
// transaction has a three-cycle AR-to-first-R latency and no inter-beat gaps;
// the second is a legal zero-latency one-beat response.
module ven_axi_read_profiler_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg ar_handshake = 1'b0;
    reg r_handshake = 1'b0;
    reg r_last = 1'b0;
    wire [31:0] busy_cycles, first_wait_cycles;

    ven_axi_read_profiler dut (
        .clk(clk), .rst(rst), .ar_handshake(ar_handshake),
        .r_handshake(r_handshake), .r_last(r_last),
        .busy_cycles(busy_cycles), .first_wait_cycles(first_wait_cycles)
    );

    task automatic tick(input ar, input r, input last);
        begin
            @(negedge clk);
            ar_handshake = ar;
            r_handshake = r;
            r_last = last;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        tick(0, 0, 0);
        rst = 1'b0;

        // AR @ t0; first R @ t3; final R @ t5.  busy=5, first=3,
        // beats=3, transactions=1, therefore inter-beat gaps=0.
        tick(1, 0, 0);
        tick(0, 0, 0);
        tick(0, 0, 0);
        tick(0, 1, 0);
        tick(0, 1, 0);
        tick(0, 1, 1);
        if (busy_cycles !== 32'd5 || first_wait_cycles !== 32'd3) begin
            $display("PROFILER FAIL first transaction busy=%0d first=%0d", busy_cycles, first_wait_cycles);
            $fatal;
        end

        // Same-cycle AR + RLAST adds no latency, and leaves the recorder idle
        // for the following transaction.
        tick(1, 1, 1);
        tick(0, 0, 0);
        if (busy_cycles !== 32'd5 || first_wait_cycles !== 32'd3) begin
            $display("PROFILER FAIL zero-latency transaction busy=%0d first=%0d", busy_cycles, first_wait_cycles);
            $fatal;
        end

        // A second delayed single-beat transaction checks re-arming: latency
        // two increments both counters by two.
        tick(1, 0, 0);
        tick(0, 0, 0);
        tick(0, 1, 1);
        if (busy_cycles !== 32'd7 || first_wait_cycles !== 32'd5) begin
            $display("PROFILER FAIL re-arm busy=%0d first=%0d", busy_cycles, first_wait_cycles);
            $fatal;
        end

        $display("VEN-AXI-READ-PROFILER-TB-OK");
        $finish;
    end
endmodule
