`timescale 1ns/1ps
`default_nettype none
module ven_video_capture_tb;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst_n = 1'b0, arm = 1'b0, ce = 1'b0, blank_n = 1'b0, hs = 1'b0, vs = 1'b0;
    reg [7:0] r = 0, g = 0, b = 0;
    reg [16:0] rd_addr = 0; reg rd_en = 0;
    wire [31:0] rd_data; wire ready, active, overrun; wire [31:0] seq; wire [63:0] stamp;
    wire [11:0] width, height; wire [19:0] pixels;

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
    integer wide_x, wide_y;
    task frame720x400;
        begin
            for (wide_y=0; wide_y<400; wide_y=wide_y+1) begin
                hsync;
                for (wide_x=0; wide_x<720; wide_x=wide_x+1)
                    pixel(8'he0, 8'h80, 8'h40);
            end
            hsync;
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

        // The practical reason for the wider private BRAM image: firmware
        // text scanout is 720x400 (288000 RGB332 bytes), not Mode 13h's
        // 320x200.  It must freeze as one complete rendered frame, with no
        // overrun and no truncation of the widened metadata fields.
        arm=1'b1; @(negedge clk); arm=1'b0;
        vsync; frame720x400; vsync;
        repeat (2) @(negedge clk);
        if (!ready || active || overrun || seq != 3 || width != 720 || height != 400 || pixels != 288000)
            $fatal(1, "wide-frame metadata r=%b a=%b o=%b seq=%0d %0dx%0d pix=%0d", ready, active, overrun, seq, width, height, pixels);
        $display("VEN_VIDEO_CAPTURE_TB_OK seq=%0d stamp=%0d", seq, stamp);
        $finish;
    end
endmodule
`default_nettype wire
