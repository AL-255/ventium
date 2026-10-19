// ven_video_capture.sv -- passive, single-frame VGA scan-out recorder.
//
// The ao486 VGA RAM has exactly two ports (CPU writes and scan-out reads), so
// it must not be read by a PS debug client.  This block instead samples the
// already-rendered pixel stream.  It has no path back into the guest, VGA, or
// core: `arm` only enables writes into this private BRAM and `frame_ready`
// freezes that BRAM until software has drained the completed frame.
//
// RGB332 preserves the rendered palette image while keeping a complete 720x400
// text-mode scanout to 288 KiB.  The default 512-KiB private BRAM image leaves
// safe headroom for the VGA modes used by FreeDOS/Quake without consuming CLB
// LUTRAM or touching the CPU/VGA memory ports.
`timescale 1ns/1ps
`default_nettype none
module ven_video_capture #(
    parameter integer FRAME_BYTES = 524288,
    parameter integer FRAME_AW = $clog2(FRAME_BYTES)
) (
    input  wire        clk,
    input  wire        rst_n,

    // PS control/read port.  `arm` is a one-cycle W1P pulse.  `rd_en` has a
    // one-clock synchronous response in `rd_data`.
    input  wire        arm,
    input  wire [FRAME_AW-3:0] rd_addr,
    input  wire        rd_en,
    output reg  [31:0] rd_data,

    // VGA scan-out signals, all in clk's domain in the RK integration.
    input  wire        video_ce,
    input  wire        video_blank_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire [7:0]  video_r,
    input  wire [7:0]  video_g,
    input  wire [7:0]  video_b,

    output reg         frame_ready,
    output reg         capture_active,
    output reg         frame_overrun,
    output reg  [31:0] frame_sequence,
    output reg  [63:0] frame_cycle,
    output reg  [11:0] frame_width,
    output reg  [11:0] frame_height,
    output reg  [FRAME_AW:0] frame_pixels
);
    localparam integer FRAME_WORDS = FRAME_BYTES / 4;

    // A 32-bit-wide byte-write BRAM produces one frozen scanout image with no
    // LUTRAM and permits PS reads while the capture side is stopped at READY.
    (* ram_style = "block" *) reg [31:0] frame_mem [0:FRAME_WORDS-1];

    reg [63:0] cycle_count;
    reg        arm_pending;
    reg        hsync_q, vsync_q;
    reg        line_had_pixel;
    reg [11:0] line_x;
    reg [11:0] line_y;
    reg [11:0] width_seen;
    reg [11:0] height_seen;
    reg [FRAME_AW:0] write_index;

    wire hsync_rise = video_hsync & ~hsync_q;
    wire vsync_rise = video_vsync & ~vsync_q;
    wire active_pixel = video_ce & video_blank_n & ~video_vsync;
    wire [7:0] rgb332 = {video_r[7:5], video_g[7:5], video_b[7:6]};

    // Dedicated synchronous BRAM read port.  The management bridge waits the
    // required cycle before exposing this value on AXI-Lite.
    always @(posedge clk) begin
        if (rd_en)
            rd_data <= frame_mem[rd_addr];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count    <= 64'd0;
            arm_pending    <= 1'b0;
            hsync_q        <= 1'b0;
            vsync_q        <= 1'b0;
            line_had_pixel <= 1'b0;
            line_x         <= '0;
            line_y         <= '0;
            width_seen     <= '0;
            height_seen    <= '0;
            write_index    <= '0;
            frame_ready    <= 1'b0;
            capture_active <= 1'b0;
            frame_overrun  <= 1'b0;
            frame_sequence <= 32'd0;
            frame_cycle    <= 64'd0;
            frame_width    <= '0;
            frame_height   <= '0;
            frame_pixels   <= '0;
        end else begin
            cycle_count <= cycle_count + 64'd1;

            // Re-arm is deliberately accepted only after software has seen a
            // complete frame.  It cannot tear a buffer that the PS is reading.
            if (arm && !capture_active) begin
                arm_pending <= 1'b1;
                frame_ready <= 1'b0;
                frame_overrun <= 1'b0;
            end

            if (video_ce) begin
                // Treat `video_ce` as the pixel-stream clock enable.  The
                // source changes sync only on that stream, and sampling the
                // history here also makes a sparse CE safe.
                hsync_q <= video_hsync;
                vsync_q <= video_vsync;
                // A VSYNC edge is the unambiguous capture boundary.  Do not
                // infer a frame from a fixed scan-line count: VGA modes and
                // polarity are programmable.
                if (vsync_rise) begin
                    if (capture_active) begin
                        capture_active <= 1'b0;
                        frame_ready    <= 1'b1;
                        frame_sequence <= frame_sequence + 32'd1;
                        frame_cycle    <= cycle_count;
                        frame_width    <= width_seen;
                        frame_height   <= height_seen;
                        frame_pixels   <= write_index;
                    end
                    if (arm_pending) begin
                        capture_active <= 1'b1;
                        arm_pending    <= 1'b0;
                        line_had_pixel <= 1'b0;
                        line_x         <= '0;
                        line_y         <= '0;
                        width_seen     <= '0;
                        height_seen    <= '0;
                        write_index    <= '0;
                    end
                end else if (capture_active) begin
                    // Synchronization happens during blanking.  Counting
                    // only lines which carried an active pixel rejects the
                    // vertical porch without assuming a particular mode.
                    if (hsync_rise) begin
                        line_x <= '0;
                        if (line_had_pixel) begin
                            line_y <= line_y + 1'b1;
                            line_had_pixel <= 1'b0;
                        end
                    end

                    if (active_pixel) begin
                        line_had_pixel <= 1'b1;
                        line_x <= line_x + 1'b1;
                        if (line_x + 1'b1 > width_seen)
                            width_seen <= line_x + 1'b1;
                        if (line_y + 1'b1 > height_seen)
                            height_seen <= line_y + 1'b1;

                        if (write_index < FRAME_BYTES) begin
                            case (write_index[1:0])
                                2'd0: frame_mem[write_index[FRAME_AW-1:2]][7:0]   <= rgb332;
                                2'd1: frame_mem[write_index[FRAME_AW-1:2]][15:8]  <= rgb332;
                                2'd2: frame_mem[write_index[FRAME_AW-1:2]][23:16] <= rgb332;
                                2'd3: frame_mem[write_index[FRAME_AW-1:2]][31:24] <= rgb332;
                            endcase
                            write_index <= write_index + 1'b1;
                        end else begin
                            frame_overrun <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
