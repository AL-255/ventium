`timescale 1ns/1ps
// Focused transport regression: the hosted device must be indistinguishable
// from a serial PS/2 keyboard to the existing ao486 8042.  It injects Set-2
// A (1c), waits for IRQ1, then consumes port 60h and checks translated Set-1
// A (1e).  No guest RAM or board-specific debug shortcut participates.
module ven_ps2_kbd_inject_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg inject_valid = 1'b0;
    reg [7:0] inject_data = 8'd0;
    wire inject_ready, inject_busy;
    wire host_clk_release, host_dat_release, dev_clk_release, dev_dat_release;
    wire ps2_clk = host_clk_release & dev_clk_release;
    wire ps2_dat = host_dat_release & dev_dat_release;

    reg [3:0] io_address = 4'd0;
    reg io_read = 1'b0;
    reg io_write = 1'b0;
    reg [7:0] io_writedata = 8'd0;
    wire [7:0] io_readdata;
    wire irq_keyb, irq_mouse, output_a20_enable, output_reset_n, a20_enable;
    wire mouse_clk_out, mouse_dat_out;
    integer cycles;

    always #5 clk = ~clk;

    ven_ps2_kbd_inject u_inject (
        .clk(clk), .rst_n(rst_n), .inject_valid(inject_valid), .inject_data(inject_data),
        .inject_ready(inject_ready), .inject_busy(inject_busy),
        .host_clk_release(host_clk_release), .host_dat_release(host_dat_release),
        .dev_clk_release(dev_clk_release), .dev_dat_release(dev_dat_release)
    );

    ps2 u_ps2 (
        .clk(clk), .rst_n(rst_n), .irq_keyb(irq_keyb), .irq_mouse(irq_mouse),
        .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_cs(1'b1), .ctl_cs(1'b0),
        .output_a20_enable(output_a20_enable), .output_reset_n(output_reset_n), .a20_enable(a20_enable),
        .ps2_kbclk(ps2_clk), .ps2_kbdat(ps2_dat),
        .ps2_kbclk_out(host_clk_release), .ps2_kbdat_out(host_dat_release),
        .ps2_mouseclk(1'b1), .ps2_mousedat(1'b1),
        .ps2_mouseclk_out(mouse_clk_out), .ps2_mousedat_out(mouse_dat_out)
    );

    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        if (!inject_ready || inject_busy) $fatal(1, "injector did not reset idle");

        inject_data = 8'h1c; // Set-2 make A
        inject_valid = 1'b1;
        @(posedge clk);
        inject_valid = 1'b0;

        cycles = 0;
        while (!irq_keyb && cycles < 10000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!irq_keyb) $fatal(1, "8042 never raised IRQ1 for serial Set-2 A");

        io_address = 4'h0;
        io_read = 1'b1;
        @(posedge clk);
        #1;
        io_read = 1'b0;
        if (io_readdata != 8'h1e)
            $fatal(1, "port 60h got %02x, expected translated Set-1 A (1e)", io_readdata);
        repeat (4) @(posedge clk);
        if (irq_keyb) $fatal(1, "IRQ1 remained asserted after port-60h consume");
        $display("VEN_PS2_KBD_INJECT_TB_OK cycles=%0d data=%02x", cycles, io_readdata);
        $finish;
    end
endmodule
