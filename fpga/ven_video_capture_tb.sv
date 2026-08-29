`timescale 1ns/1ps
`default_nettype none
module ven_video_capture_tb;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst_n = 1'b0, arm = 1'b0, ce = 1'b0, blank_n = 1'b0, hs = 1'b0, vs = 1'b0;
    reg [7:0] r = 0, g = 0, b = 0;
    reg [13:0] rd_addr = 0; reg rd_en = 0;
    wire [31:0] rd_data; wire ready, active, overrun; wire [31:0] seq; wire [63:0] stamp;
    wire [8:0] width, height; wire [16:0] pixels;

    ven_video_capture dut (
        .clk(clk), .rst_n(rst_n), .arm(arm), .rd_addr(rd_addr), .rd_en(rd_en), .rd_data(rd_data),
        .video_ce(ce), .video_blank_n(blank_n), .video_hsync(hs), .video_vsync(vs),
        .video_r(r), .video_g(g), .video_b(b), .frame_ready(ready), .capture_active(active),
        .frame_overrun(overrun), .frame_sequence(seq), .frame_cycle(stamp), .frame_width(width),
        .frame_height(height), .frame_pixels(pixels)
    );

    task tick; begin @(negedge clk); ce=1'b1; @(negedge clk); ce=1'b0; end endtask
    task hsync; begin hs=1'b1; tick; hs=1'b0; tick; end endtask
    task pixel(input [7:0] rv, input [7:0] gv, input [7:0] bv); begin r=rv; g=gv; b=bv; blank_n=1'b1; tick; blank_n=1'b0; tick; end endtask
    task vsync; begin vs=1'b1; tick; vs=1'b0; tick; end endtask
    task frame4x2;
        begin
            hsync; pixel(8'he0,0,0); pixel(0,8'he0,0); pixel(0,0,8'hc0); pixel(8'he0,8'he0,8'hc0);
            hsync; pixel(8'h20,8'h40,8'h80); pixel(8'h40,8'h60,8'ha0); pixel(8'h60,8'h80,8'hc0); pixel(8'h80,8'ha0,8'he0);
            hsync;
        end
    endtask
    task frame2x1;
        begin
            hsync; pixel(8'he0,0,0); pixel(0,8'he0,0); hsync;
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n=1'b1;
        arm=1'b1; @(negedge clk); arm=1'b0;
        vsync; // starts frame
        frame4x2;
        vsync; // completes it
        repeat (2) @(negedge clk);
        if (!ready || active || overrun || seq != 1 || width != 4 || height != 2 || pixels != 8) $fatal(1, "bad metadata r=%b a=%b o=%b seq=%0d %0dx%0d pix=%0d", ready, active, overrun, seq, width, height, pixels);
        rd_addr=0; rd_en=1; @(negedge clk); rd_en=0; @(negedge clk);
        if (rd_data !== 32'hFF_03_1C_E0) $fatal(1, "bad line 0 %08x", rd_data);

        // Re-arming replaces READY metadata only at the next VSYNC boundary;
        // this is the condition the host uses while draining a frame stream.
        arm=1'b1; @(negedge clk); arm=1'b0;
        if (ready || active) $fatal(1, "re-arm did not clear frozen state r=%b a=%b", ready, active);
        vsync; frame2x1; vsync;
        repeat (2) @(negedge clk);
        if (!ready || active || overrun || seq != 2 || width != 2 || height != 1 || pixels != 2)
            $fatal(1, "bad rearm metadata r=%b a=%b o=%b seq=%0d %0dx%0d pix=%0d", ready, active, overrun, seq, width, height, pixels);
        rd_addr=0; rd_en=1; @(negedge clk); rd_en=0; @(negedge clk);
        // Capture buffers are not bulk-cleared.  The final word of a frame
        // shorter than four pixels may retain old upper lanes, which the
        // documented exact-pixel stream deliberately never emits.
        if (rd_data[15:0] !== 16'h1C_E0) $fatal(1, "bad rearm payload lanes %08x", rd_data);
        $display("VEN_VIDEO_CAPTURE_TB_OK seq=%0d stamp=%0d", seq, stamp);
        $finish;
    end
endmodule
`default_nettype wire
