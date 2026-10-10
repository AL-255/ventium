// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Byte transport for a debug-hosted PS/2 *device*, not an 8042 replacement.
// Both inputs are release levels from the synchronous controller; wire-AND
// each output with its corresponding host output to form the physical line.
// No guest memory, interrupt, CPU or controller-FIFO shortcut is used.
//
// TX owns one byte after valid/ready. Completion and host-preemption are
// distinct pulses: software must never count an aborted byte as delivered.
// RX owns one byte until valid/ready; parity/stop errors accompany that byte.
// A command waits for an empty RX slot before device clocks/ACK are supplied.
// An attached device's command policy (ACK/RESEND/ID/motion packets) belongs
// above this transport. This module alone is not a functional mouse.
`default_nettype none
module ven_ps2_device #(
    parameter integer CLK_HZ = 40_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    output wire       tx_ready,
    output reg        tx_done,
    output reg        tx_aborted,
    output reg        rx_valid,
    output reg  [7:0] rx_data,
    output reg  [1:0] rx_error, // bit 0 odd-parity error, bit 1 stop-bit error
    input  wire       rx_ready,
    output reg        rx_aborted,
    input  wire       host_clk_release,
    input  wire       host_dat_release,
    output wire       dev_clk_release,
    output wire       dev_dat_release
);
    // 40 us high/low => 12.5 kHz. Wait 100 us of continuous idle before TX.
    // Wide arithmetic makes the supported hardware clocks safe from overflow.
    localparam integer HALF_CYCLES = (64'(CLK_HZ) + 64'd24_999) / 64'd25_000;
    localparam integer CELL_CYCLES = 2 * HALF_CYCLES;
    localparam integer IDLE_CYCLES = (64'(CLK_HZ) + 64'd9_999) / 64'd10_000;
    localparam integer CELL_CW = (CELL_CYCLES > 1) ? $clog2(CELL_CYCLES) : 1;
    localparam integer IDLE_CW = (IDLE_CYCLES > 1) ? $clog2(IDLE_CYCLES) : 1;
    initial begin
        if (CLK_HZ < 1_000_000 || CLK_HZ > 100_000_000)
            $fatal(1, "ven_ps2_device supports 1..100 MHz synchronous hosts");
    end
    localparam [2:0] IDLE=0, WAIT_TX=1, TX=2, WAIT_RX=3, RX=4;
    reg [2:0] state;
    reg host_clk_q;
    reg [10:0] tx_frame;
    reg [7:0] rx_shift;
    reg [1:0] rx_errors_q;
    reg [3:0] bit_index;
    reg [CELL_CW-1:0] cell_count;
    reg [IDLE_CW-1:0] idle_count;
    wire request_to_send = !host_clk_q && host_clk_release && !host_dat_release;
    wire rx_slot_free = !rx_valid || rx_ready;

    assign tx_ready = state == IDLE && !rx_valid && !request_to_send;
    assign dev_clk_release = (state == TX || state == RX) ?
                             (cell_count < HALF_CYCLES) : 1'b1;
    assign dev_dat_release = state == TX ? tx_frame[bit_index] :
                             (state == RX && bit_index == 10) ? 1'b0 : 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            host_clk_q <= 1'b1;
            tx_frame <= 11'h7ff;
            rx_shift <= 0;
            rx_errors_q <= 0;
            bit_index <= 0;
            cell_count <= 0;
            idle_count <= 0;
            tx_done <= 0;
            tx_aborted <= 0;
            rx_valid <= 0;
            rx_data <= 0;
            rx_error <= 0;
            rx_aborted <= 0;
        end else begin
            host_clk_q <= host_clk_release;
            tx_done <= 0;
            tx_aborted <= 0;
            rx_aborted <= 0;
            if (rx_valid && rx_ready) rx_valid <= 0;
            case (state)
                IDLE: begin
                    cell_count <= 0;
                    idle_count <= 0;
                    bit_index <= 0;
                    if (request_to_send) begin
                        rx_shift <= 0;
                        rx_errors_q <= 0;
                        state <= rx_slot_free ? RX : WAIT_RX;
                    end else if (tx_valid && tx_ready) begin
                        tx_frame <= {1'b1, ~^tx_data, tx_data, 1'b0};
                        state <= WAIT_TX;
                    end
                end
                WAIT_TX: begin
                    if (request_to_send) begin
                        // The client decides whether to retry interrupted
                        // output or replace it with a command response.
                        tx_aborted <= 1;
                        rx_shift <= 0;
                        rx_errors_q <= 0;
                        state <= rx_slot_free ? RX : WAIT_RX;
                        cell_count <= 0;
                        bit_index <= 0;
                    end else if (host_clk_release && host_dat_release) begin
                        if (idle_count == IDLE_CYCLES - 1) begin
                            state <= TX;
                            cell_count <= 0;
                            bit_index <= 0;
                        end else idle_count <= idle_count + 1'b1;
                    end else idle_count <= 0;
                end
                TX: begin
                    if (!host_clk_release) begin
                        // Host inhibition can truncate a frame. Never emit
                        // a suffix after release or report false completion.
                        state <= IDLE;
                        tx_aborted <= 1;
                    end else if (cell_count == CELL_CYCLES - 1) begin
                        cell_count <= 0;
                        if (bit_index == 10) begin
                            state <= IDLE;
                            tx_done <= 1;
                        end else bit_index <= bit_index + 1'b1;
                    end else cell_count <= cell_count + 1'b1;
                end
                WAIT_RX: begin
                    if (host_clk_release && host_dat_release) begin
                        state <= IDLE;
                        rx_aborted <= 1;
                    end else if (rx_slot_free && host_clk_release) begin
                        state <= RX;
                        cell_count <= 0;
                        bit_index <= 0;
                    end
                end
                RX: begin
                    if (!host_clk_release) begin
                        state <= IDLE;
                        rx_aborted <= 1;
                    end else if (cell_count == CELL_CYCLES - 1) begin
                        cell_count <= 0;
                        // The controller changes its data after the falling
                        // edge. Sample at the end of the low phase, before
                        // the device raises the clock again.
                        if (bit_index < 8) rx_shift[bit_index] <= host_dat_release;
                        if (bit_index == 8)
                            rx_errors_q[0] <= !(^{rx_shift, host_dat_release});
                        if (bit_index == 9) rx_errors_q[1] <= !host_dat_release;
                        if (bit_index == 10) begin
                            rx_data <= rx_shift;
                            rx_error <= rx_errors_q;
                            rx_valid <= 1;
                            state <= IDLE;
                        end else bit_index <= bit_index + 1'b1;
                    end else cell_count <= cell_count + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
