// ven_ps2_kbd_inject.v -- Debug-hosted PS/2 keyboard device.
//
// The RK wrapper has no physical PS/2 connector.  This block provides a
// deliberately narrow substitute for the missing *device* only: software
// submits raw Set-2 bytes via the versioned AXI-Lite debug register, and this
// module serialises them on the two existing open-drain PS/2 lines.  It is not
// a guest-memory shortcut and has no path into the CPU or keyboard FIFO.
//
// One byte is accepted only while ready.  Software must wait for ready after
// every write; this preserves byte order and naturally back-pressures while
// the 8042 is talking to the device.  Timings scale with the actual system
// clock and preserve the original 128/128 phases and 80-cycle idle interval
// at 3.125 MHz.  This is approximately a 12 kHz PS/2 clock; the idle interval
// preserves the existing transport contract rather than proving a complete
// physical-device protocol.  Framing matches the simulation device model.
`default_nettype none
module ven_ps2_kbd_inject #(
    parameter CLK_HZ = 32'd3_125_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       inject_valid,
    input  wire [7:0] inject_data,
    output wire       inject_ready,
    output wire       inject_busy,
    // Release levels driven by the 8042 host side (1=release, 0=pull low).
    input  wire       host_clk_release,
    input  wire       host_dat_release,
    // Device open-drain levels to wire-AND with the host signals.
    output wire       dev_clk_release,
    output wire       dev_dat_release
);
    // Use wide intermediate arithmetic: 128 * 40 MHz exceeds 32 bits.
    // Ceiling division avoids shortening either legacy physical interval.
    localparam integer HALF_CYCLES = (64'd128 * CLK_HZ + 64'd3_124_999) / 64'd3_125_000;
    localparam integer CELL_CYCLES = 2 * HALF_CYCLES;
    localparam integer START_IDLE_CYCLES = (64'd80 * CLK_HZ + 64'd3_124_999) / 64'd3_125_000;
    localparam integer CELL_CW = (CELL_CYCLES > 1) ? $clog2(CELL_CYCLES) : 1;
    localparam integer IDLE_CW = (START_IDLE_CYCLES > 1) ? $clog2(START_IDLE_CYCLES) : 1;

    localparam [1:0] IDLE = 2'd0, WAIT_IDLE = 2'd1, SEND = 2'd2;
    reg [1:0] state;
    reg [7:0] byte_q;
    reg [10:0] frame_q;
    reg [3:0] bit_idx;
    reg [CELL_CW-1:0] half_count;
    reg [IDLE_CW-1:0] idle_count;

    assign inject_ready = (state == IDLE);
    assign inject_busy = (state != IDLE);
    // The device leaves both lines released outside SEND.  During a send it
    // drives data for the whole cell and supplies a high then low clock phase,
    // exactly like the established simulation keyboard device.
    assign dev_dat_release = (state == SEND) ? frame_q[bit_idx] : 1'b1;
    assign dev_clk_release = (state == SEND) ? (half_count < HALF_CYCLES) : 1'b1;

    function [10:0] ps2_frame;
        input [7:0] data;
        reg parity;
        integer i;
        begin
            parity = 1'b1;
            for (i = 0; i < 8; i = i + 1) parity = parity ^ data[i];
            ps2_frame = {1'b1, parity, data, 1'b0}; // stop, odd parity, LSB-first data, start
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            byte_q <= 8'd0;
            frame_q <= 11'h7ff;
            bit_idx <= 4'd0;
            half_count <= 0;
            idle_count <= 0;
        end else begin
            case (state)
                IDLE: begin
                    idle_count <= 0;
                    if (inject_valid) begin
                        byte_q <= inject_data;
                        state <= WAIT_IDLE;
                    end
                end
                WAIT_IDLE: begin
                    // Do not begin a device frame while the host owns either
                    // open-drain line.  Requiring a continuous idle interval
                    // also separates back-to-back bytes cleanly.
                    if (host_clk_release && host_dat_release) begin
                        if (idle_count == START_IDLE_CYCLES - 1'b1) begin
                            frame_q <= ps2_frame(byte_q);
                            bit_idx <= 4'd0;
                            half_count <= 0;
                            state <= SEND;
                        end else begin
                            idle_count <= idle_count + 1'b1;
                        end
                    end else begin
                        idle_count <= 0;
                    end
                end
                SEND: begin
                    if (!host_clk_release) begin
                        // The host owns the wire: do not shift an invisible
                        // suffix and then advertise the queued byte as done.
                        // Keep the accepted byte and restart its complete frame
                        // after the original continuous-idle requirement.
                        // A stop falling edge already observed for a full
                        // synchronous clock completes the byte instead; never
                        // duplicate it merely because inhibition follows stop.
                        if (bit_idx == 4'd10 && half_count > HALF_CYCLES)
                            state <= IDLE;
                        else
                            state <= WAIT_IDLE;
                        bit_idx <= 4'd0;
                        half_count <= 0;
                        idle_count <= 0;
                    end else if (half_count == CELL_CYCLES - 1'b1) begin
                        half_count <= 0;
                        if (bit_idx == 4'd10) begin
                            state <= IDLE;
                            bit_idx <= 4'd0;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        half_count <= half_count + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
