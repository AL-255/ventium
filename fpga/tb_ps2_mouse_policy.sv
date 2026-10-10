`timescale 1ps/1ps
// Interactive protocol microbench: Python supplies device policy, while the
// actual 8042, serial transport, AUX FIFO and IRQ12 remain RTL. No force/DPI.
module tb_ps2_mouse_policy;
    parameter integer HZ = 3125000;
    localparam integer HALF_PS = 500000000000 / HZ;
    localparam integer WAIT_LIMIT = HZ / 20; // 50 ms per operation
    reg clk=0, rst_n=0;
    always #HALF_PS clk = ~clk;
    reg tx_valid=0, rx_ready=0;
    reg [7:0] tx_data=0;
    wire tx_ready, tx_done, tx_aborted, rx_valid, rx_aborted;
    wire [7:0] rx_data;
    wire [1:0] rx_error;
    wire hc, hd, dc, dd, irq_mouse, irq_keyb;
    reg [3:0] io_address=0;
    reg io_read=0, io_write=0;
    reg [7:0] io_writedata=0;
    wire [7:0] io_readdata;
    wire unused_a20, unused_output_a20, unused_reset, unused_kc, unused_kd;
    integer sent=0;
    always @(posedge clk) begin
        if (tx_done) sent <= sent + 1;
        if (tx_aborted || rx_aborted) $fatal(1,"unexpected serial abort");
    end
    ven_ps2_device #(.CLK_HZ(HZ)) device (
        .clk(clk), .rst_n(rst_n), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_done(tx_done), .tx_aborted(tx_aborted),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error),
        .rx_ready(rx_ready), .rx_aborted(rx_aborted),
        .host_clk_release(hc), .host_dat_release(hd),
        .dev_clk_release(dc), .dev_dat_release(dd)
    );
    ps2 controller (
        .clk(clk), .rst_n(rst_n), .irq_keyb(irq_keyb), .irq_mouse(irq_mouse),
        .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_cs(1'b1), .ctl_cs(1'b0),
        .output_a20_enable(unused_output_a20), .output_reset_n(unused_reset),
        .a20_enable(unused_a20), .ps2_kbclk(1'b1), .ps2_kbdat(1'b1),
        .ps2_kbclk_out(unused_kc), .ps2_kbdat_out(unused_kd),
        .ps2_mouseclk(hc & dc), .ps2_mousedat(hd & dd),
        .ps2_mouseclk_out(hc), .ps2_mousedat_out(hd)
    );
    task io_wr(input [3:0] address, input [7:0] value);
        @(negedge clk); io_address=address; io_writedata=value; io_write=1;
        @(negedge clk); io_write=0;
        repeat (3) @(negedge clk);
    endtask
    task io_rd(input [3:0] address, output [7:0] value);
        @(negedge clk); io_address=address; io_read=1;
        @(posedge clk); #1; value=io_readdata;
        @(negedge clk); io_read=0;
        repeat (3) @(negedge clk);
    endtask
    integer operation, value, count, scan, before_sent, bit_number;
    reg [7:0] status, result;
    reg [10:0] expected;
    initial begin
        repeat (8) @(negedge clk); rst_n=1;
        repeat (8) @(negedge clk);
        $display("READY %0d",HZ); $fflush();
        forever begin
            scan=$fscanf(32'h80000000,"%d %d",operation,value);
            if (scan != 2) $fatal(1,"truncated policy input");
            case (operation)
                1: begin
                    io_rd(4,status);
                    if (status[1:0] != 0) $fatal(1,"host input/output buffer not empty");
                    io_wr(4,8'hd4); io_wr(0,8'(value));
                    count=0;
                    while (!rx_valid && count < WAIT_LIMIT) begin
                        @(negedge clk); count=count+1;
                    end
                    if (!rx_valid) $fatal(1,"host serial command timeout");
                    $display("RX %0d %0d",rx_data,rx_error); $fflush();
                    @(negedge clk); rx_ready=1;
                    @(negedge clk); rx_ready=0;
                end
                2: begin
                    before_sent=sent;
                    if (!tx_ready) $fatal(1,"transport not ready for offered byte");
                    @(negedge clk); tx_data=8'(value); tx_valid=1;
                    @(negedge clk); tx_valid=0;
                    expected={1'b1,~^tx_data,tx_data,1'b0};
                    for (bit_number=0;bit_number<11;bit_number=bit_number+1) begin
                        @(negedge dc);
                        if ((hd & dd) !== expected[bit_number])
                            $fatal(1,"policy wire bit/parity mismatch");
                        @(posedge dc);
                    end
                    count=0;
                    while ((!irq_mouse || sent==before_sent) && count < WAIT_LIMIT) begin
                        @(negedge clk); count=count+1;
                    end
                    if (!irq_mouse || irq_keyb || sent != before_sent+1)
                        $fatal(1,"policy byte missing IRQ12/delivery");
                    io_rd(4,status);
                    if ((status & 8'ha3) != 8'h21) $fatal(1,"bad AUX/OBF/IBF/parity status");
                    io_rd(0,result);
                    if (result != 8'(value)) $fatal(1,"port60 differs from offered policy byte");
                    repeat (8) @(negedge clk);
                    if (irq_mouse) $fatal(1,"policy byte IRQ12 not consumed");
                    $display("TX %0d",result); $fflush();
                end
                3: begin
                    $display("PS2-MOUSE-WIRE-OK hz=%0d completed=%0d",HZ,sent);
                    $fflush(); $finish;
                end
                default: $fatal(1,"unknown policy operation");
            endcase
        end
    end
    initial begin
        #2000000000000;
        $fatal(1,"policy wire test virtual deadline");
    end
endmodule
