`timescale 1ps/1ps
module ps2_rate_case #(
    parameter integer HZ = 3125000,
    parameter integer HALF_PS = 160000,
    parameter integer EXPECT_HALF = 128,
    parameter integer EXPECT_IDLE = 80
) (output reg done = 0);
    reg clk = 0;
    reg rst_n = 0;
    reg inject_valid = 0;
    reg [7:0] inject_data = 0;
    reg host_clk_release = 1;
    reg host_dat_release = 1;
    wire dev_clk_release, dev_dat_release, ready, busy;
    wire kbclk = host_clk_release & dev_clk_release;
    wire kbdat = host_dat_release & dev_dat_release;
    always #HALF_PS clk = ~clk;
    generate
        if (HZ == 3125000) begin : legacy_default
            ven_ps2_kbd_inject dut (
                .clk(clk), .rst_n(rst_n), .inject_valid(inject_valid),
                .inject_data(inject_data), .inject_ready(ready), .inject_busy(busy),
                .host_clk_release(host_clk_release), .host_dat_release(host_dat_release),
                .dev_clk_release(dev_clk_release), .dev_dat_release(dev_dat_release));
        end else begin : scaled
            ven_ps2_kbd_inject #(.CLK_HZ(HZ)) dut (
                .clk(clk), .rst_n(rst_n), .inject_valid(inject_valid),
                .inject_data(inject_data), .inject_ready(ready), .inject_busy(busy),
                .host_clk_release(host_clk_release), .host_dat_release(host_dat_release),
                .dev_clk_release(dev_clk_release), .dev_dat_release(dev_dat_release));
        end
    endgenerate
    integer frames = 0;
    integer checked_bits = 0;
    task send_byte(input [7:0] value, input integer inhibit);
        reg [10:0] received;
        reg [10:0] expected;
        time accepted_at, released_at, started_at, fell_at, previous_fall;
        integer i;
        begin
            wait (ready === 1);
            @(negedge clk);
            if (inhibit == 1) host_clk_release = 0;
            if (inhibit == 2) host_dat_release = 0;
            inject_data = value;
            inject_valid = 1;
            @(posedge clk);
            accepted_at = $time;
            #1;
            if (ready !== 0 || busy !== 1)
                $fatal(1, "HZ%0d byte not owned after valid strobe", HZ);
            @(negedge clk);
            inject_valid = 0;
            if (inhibit != 0) begin
                repeat (23) begin
                    @(posedge clk); #1;
                    if (dev_clk_release !== 1 || dev_dat_release !== 1 || busy !== 1)
                        $fatal(1, "HZ%0d device started while host inhibited", HZ);
                end
                @(negedge clk);
                host_clk_release = 1;
                host_dat_release = 1;
                released_at = $time;
            end
            @(negedge dev_dat_release);
            started_at = $time;
            if (inhibit == 0) begin
                if (started_at - accepted_at != EXPECT_IDLE * 2 * HALF_PS)
                    $fatal(1, "HZ%0d default idle interval wrong", HZ);
            end else begin
                if (started_at - released_at != (2 * EXPECT_IDLE - 1) * HALF_PS)
                    $fatal(1, "HZ%0d restarted idle interval wrong", HZ);
            end
            expected = {1'b1, ~^value, value, 1'b0};
            for (i = 0; i < 11; i = i + 1) begin
                @(negedge kbclk);
                fell_at = $time;
                received[i] = kbdat;
                if (kbdat !== expected[i])
                    $fatal(1, "HZ%0d wrong data/parity/start/stop bit%0d for byte%02x", HZ, i, value);
                if (i == 0) begin
                    if (fell_at - started_at != EXPECT_HALF * 2 * HALF_PS)
                        $fatal(1, "HZ%0d first high half-period wrong", HZ);
                end else if (fell_at - previous_fall != EXPECT_HALF * 4 * HALF_PS)
                    $fatal(1, "HZ%0d full bit period wrong", HZ);
                previous_fall = fell_at;
                @(posedge kbclk);
                if ($time - fell_at != EXPECT_HALF * 2 * HALF_PS)
                    $fatal(1, "HZ%0d low half-period wrong", HZ);
                checked_bits = checked_bits + 1;
            end
            #1;
            if (received !== expected || ^received[9:1] !== 1'b1)
                $fatal(1, "HZ%0d decoded frame/odd parity wrong", HZ);
            if (ready !== 1 || busy !== 0 || dev_clk_release !== 1 || dev_dat_release !== 1)
                $fatal(1, "HZ%0d transport not idle at frame end", HZ);
            frames = frames + 1;
        end
    endtask
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        // Exact independent pin oracle: ordinary make, break prefix/suffix,
        // all-zero/all-one data and keyboard reply patterns in submission order.
        send_byte(8'h1c, 1);
        send_byte(8'hf0, 0);
        send_byte(8'h5a, 0);
        send_byte(8'h00, 2);
        send_byte(8'hff, 0);
        send_byte(8'haa, 0);
        $display("PS2-RATE-OK hz=%0d half_cycles=%0d idle_cycles=%0d frames=%0d checked_bits=%0d", HZ, EXPECT_HALF, EXPECT_IDLE, frames, checked_bits);
        done = 1;
    end
endmodule

module tb_ps2_rate;
    wire legacy_done, scaled_done;
    ps2_rate_case legacy (.done(legacy_done));
    ps2_rate_case #(.HZ(40000000), .HALF_PS(12500),
                    .EXPECT_HALF(1639), .EXPECT_IDLE(1024))
        scaled (.done(scaled_done));
    initial begin
        wait (legacy_done && scaled_done);
        $display("PS2-RATE-ALL-OK profiles=2 frames=12 bits=132");
        $finish;
    end
    initial begin
        #20000000000;
        $fatal(1, "pin test timeout");
    end
endmodule
