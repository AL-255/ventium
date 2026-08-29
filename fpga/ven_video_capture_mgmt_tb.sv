`timescale 1ns/1ps
`default_nettype none
module ven_video_capture_mgmt_tb;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg [15:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg [31:0] wdata = 0; reg [3:0] wstrb = 4'hf; reg wvalid = 0; wire wready;
    wire [1:0] bresp; wire bvalid; reg bready = 1'b1;
    reg [15:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1'b1;

    wire cap_arm, cap_rd_en; wire [16:0] cap_rd_addr; wire [31:0] cap_rd_data;
    wire cap_ready, cap_active, cap_overrun; wire [31:0] cap_seq; wire [63:0] cap_cycle;
    wire [11:0] cap_width, cap_height; wire [19:0] cap_pixels;
    reg ce = 0, blank_n = 0, hs = 0, vs = 0; reg [7:0] vr = 0, vg = 0, vb = 0;

    ven_mgmt_axil u_mgmt (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .cap_arm(cap_arm), .cap_rd_addr(cap_rd_addr), .cap_rd_en(cap_rd_en), .cap_rd_data(cap_rd_data),
        .cap_frame_ready(cap_ready), .cap_capture_active(cap_active), .cap_frame_overrun(cap_overrun),
        .cap_frame_sequence(cap_seq), .cap_frame_cycle(cap_cycle), .cap_frame_width(cap_width),
        .cap_frame_height(cap_height), .cap_frame_pixels(cap_pixels)
    );

    ven_video_capture u_capture (
        .clk(clk), .rst_n(rst_n), .arm(cap_arm), .rd_addr(cap_rd_addr), .rd_en(cap_rd_en), .rd_data(cap_rd_data),
        .video_ce(ce), .video_blank_n(blank_n), .video_hsync(hs), .video_vsync(vs),
        .video_r(vr), .video_g(vg), .video_b(vb), .frame_ready(cap_ready), .capture_active(cap_active),
        .frame_overrun(cap_overrun), .frame_sequence(cap_seq), .frame_cycle(cap_cycle),
        .frame_width(cap_width), .frame_height(cap_height), .frame_pixels(cap_pixels)
    );

    task awrite(input [15:0] addr, input [31:0] data);
        begin
            @(negedge clk); awaddr=addr; wdata=data; awvalid=1; wvalid=1;
            @(negedge clk); awvalid=0; wvalid=0;
            wait (bvalid); @(negedge clk);
        end
    endtask
    task aread(input [15:0] addr, output [31:0] data);
        begin
            @(negedge clk); araddr=addr; arvalid=1;
            @(negedge clk); arvalid=0;
            wait (rvalid); data=rdata; @(negedge clk);
        end
    endtask
    task tick; begin @(negedge clk); ce=1; @(negedge clk); ce=0; end endtask
    task hsync; begin hs=1; tick; hs=0; tick; end endtask
    task vsync; begin vs=1; tick; vs=0; tick; end endtask
    task pixel(input [7:0] r, input [7:0] g, input [7:0] b);
        begin vr=r; vg=g; vb=b; blank_n=1; tick; blank_n=0; tick; end
    endtask
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

    reg [31:0] q;
    initial begin
        repeat (3) @(negedge clk); rst_n=1;
        awrite(16'h0300, 32'h1);
        vsync; frame4x2; vsync;
        aread(16'h0310, q);
        if (q[31:29] !== 3'b001 || q[28:0] != 1) $fatal(1, "bad status %08x", q);
        aread(16'h0340, q); if (q[11:0] != 4 || q[23:12] != 2) $fatal(1, "bad dims %08x", q);
        aread(16'h0350, q); if (q != 8) $fatal(1, "bad pixels %08x", q);
        awrite(16'h0360, 0);
        aread(16'h0370, q); if (q != 32'hff031ce0) $fatal(1, "bad frame word %08x", q);
        // CAP_ADDR carries all 17 word-address bits.  A 512-KiB frame has
        // 131072 words, so silently retaining the old 14-bit register would
        // alias the upper three quarters of a captured text scanout.
        awrite(16'h0360, 32'h0001_0000);
        aread(16'h0360, q); if (q != 32'h0001_0000) $fatal(1, "CAP_ADDR truncated %08x", q);

        // Exercise the real AXI-Lite W1P re-arm.  READY must drop before the
        // replacement capture begins, then the synchronous CAP_DATA path must
        // expose only the new frozen payload.
        awrite(16'h0300, 32'h1);
        aread(16'h0310, q); if (q[31:29] !== 3'b000 || q[28:0] != 1) $fatal(1, "bad rearm status %08x", q);
        vsync; frame2x1; vsync;
        aread(16'h0310, q);
        if (q[31:29] !== 3'b001 || q[28:0] != 2) $fatal(1, "bad second status %08x", q);
        aread(16'h0340, q); if (q[11:0] != 2 || q[23:12] != 1) $fatal(1, "bad second dims %08x", q);
        aread(16'h0350, q); if (q != 2) $fatal(1, "bad second pixels %08x", q);
        awrite(16'h0360, 0);
        aread(16'h0370, q); if (q[15:0] != 16'h1ce0) $fatal(1, "bad second payload lanes %08x", q);
        $display("VEN_VIDEO_CAPTURE_MGMT_TB_OK seq=%0d cycle=%0d", cap_seq, cap_cycle);
        $finish;
    end
endmodule
`default_nettype wire
