// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Single-writer, loss-detectable CSR ownership for ven_ps2_device.
// All ports share clk. rst_n is the management reset; guest_reset is the
// SAME synchronous reset used by the 8042 and serial transport. No CPU,
// guest-memory, controller-FIFO or interrupt shortcut exists here.
//
// Register indices, mapped by the wrapper to distinct lane-0 addresses:
//  0 CAP (RO, "PS2", version 1)   1 STATUS (RO; bits below)
//  2 guest reset generation (RO)  3 ARM (WO, exact observed generation)
//  4 TX submit (WO, byte in bits 7:0; upper bits must be zero)
//  5 TX sequence (RO)             6 TX event ACK (WO, exact TX sequence)
//  7 RX byte/error (RO, [9:8] framing errors, [7:0] byte)
//  8 RX sequence (RO)             9 RX ACK (WO, exact RX sequence)
//  A sticky W1C ([0] RX aborted, [1] CSR/protocol error)
//
// STATUS: [0] guest reset, [1] armed, [2] TX submit possible now,
// [3] queued TX, [4] serial TX owned, [5] retained TX event,
// [6] event delivered (0=aborted), [7] RX full, [8] RX abort seen,
// [9] protocol error, [10] counter exhausted (no wrap, reset required).
// Reads never acknowledge events. A full-strobe invalid/stale write sets
// protocol error without replacing owned data. Partial writes are rejected.
// A pending TX is explicitly aborted if a host command wins before serial
// admission, avoiding a policy deadlock waiting for TX ahead of unread RX.
//
// Software must serialize MMIO, arm after observing the actual guest reset,
// confirm TX sequence advancement before policy.admitted(), resolve retained
// TX events BEFORE RX, and recheck generation around observations. Only one
// software owner is supported; a process restart is not a device reset.
// COUNTER_BITS is narrowed only by overflow tests; deployed ABI uses 32.
`default_nettype none
module ven_ps2_mailbox #(
    parameter integer COUNTER_BITS = 32
) (
    input wire clk,
    input wire rst_n,
    input wire guest_reset,
    input wire csr_write,
    input wire [3:0] csr_waddr,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    input wire [3:0] csr_raddr,
    output reg [31:0] csr_rdata,
    output wire tx_valid,
    output reg [7:0] tx_data,
    input wire tx_ready,
    input wire tx_done,
    input wire tx_aborted,
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire [1:0] rx_error,
    output wire rx_ready,
    input wire rx_aborted
);
    initial begin
        if (COUNTER_BITS < 2 || COUNTER_BITS > 32)
            $fatal(1, "ven_ps2_mailbox COUNTER_BITS must be 2..32");
    end
    localparam [1:0] TX_IDLE=0, TX_QUEUED=1, TX_ACTIVE=2, TX_EVENT=3;
    reg [1:0] tx_state;
    reg guest_reset_q, armed, epoch_exhausted;
    reg delivered, rx_full, rx_abort_seen, protocol_error;
    reg [7:0] rx_byte;
    reg [1:0] rx_errors;
    reg [COUNTER_BITS-1:0] epoch, tx_sequence, rx_sequence;
    wire can_submit = armed && !guest_reset && !epoch_exhausted &&
                      !protocol_error && tx_state == TX_IDLE &&
                      !rx_full && !rx_valid && !rx_aborted && !(&tx_sequence);
    wire cancel_queued = rx_full || rx_valid || rx_aborted;
    wire exhausted = epoch_exhausted || (&tx_sequence) || (&rx_sequence);

    assign tx_valid = rst_n && !guest_reset && tx_state == TX_QUEUED && !cancel_queued;
    assign rx_ready = rst_n && !guest_reset && !rx_full && !(&rx_sequence);

    always @* begin
        csr_rdata = 0;
        case (csr_raddr)
            4'h0: csr_rdata = 32'h5053_3201;
            4'h1: csr_rdata = {21'd0, exhausted, protocol_error, rx_abort_seen,
                              rx_full, delivered && tx_state == TX_EVENT,
                              tx_state == TX_EVENT, tx_state == TX_ACTIVE,
                              tx_state == TX_QUEUED, can_submit, armed, guest_reset};
            4'h2: csr_rdata = 32'(epoch);
            4'h5: csr_rdata = 32'(tx_sequence);
            4'h7: csr_rdata = {22'd0, rx_errors, rx_byte};
            4'h8: csr_rdata = 32'(rx_sequence);
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            epoch <= 0;
            epoch_exhausted <= 0;
            guest_reset_q <= 1;
            armed <= 0;
            tx_state <= TX_IDLE;
            tx_data <= 0;
            tx_sequence <= 0;
            delivered <= 0;
            rx_sequence <= 0;
            rx_full <= 0;
            rx_byte <= 0;
            rx_errors <= 0;
            rx_abort_seen <= 0;
            protocol_error <= 0;
        end else begin
            guest_reset_q <= guest_reset;
            if (guest_reset) begin
                if (!guest_reset_q) begin
                    if (&epoch) epoch_exhausted <= 1;
                    else epoch <= epoch + 1'b1;
                end
                armed <= 0;
                tx_state <= TX_IDLE;
                tx_data <= 0;
                tx_sequence <= 0;
                delivered <= 0;
                rx_sequence <= 0;
                rx_full <= 0;
                rx_byte <= 0;
                rx_errors <= 0;
                rx_abort_seen <= 0;
                protocol_error <= 0;
            end else begin
                // Commands do not acknowledge or overwrite a native event.
                // If an event and its ACK coincide, the old state rejects
                // that premature ACK and the newly completed event remains.
                if (csr_write) begin
                    if (csr_wstrb != 4'hf) protocol_error <= 1;
                    else case (csr_waddr)
                        4'h3: begin
                            if (!epoch_exhausted && csr_wdata == 32'(epoch) && tx_state == TX_IDLE)
                                armed <= 1;
                            else begin armed <= 0; protocol_error <= 1; end
                        end
                        4'h4: begin
                            if (can_submit && csr_wdata[31:8] == 0) begin
                                tx_data <= csr_wdata[7:0];
                                tx_sequence <= tx_sequence + 1'b1;
                                delivered <= 0;
                                tx_state <= TX_QUEUED;
                            end else protocol_error <= 1;
                        end
                        4'h6: begin
                            if (armed && tx_state == TX_EVENT && csr_wdata == 32'(tx_sequence))
                                tx_state <= TX_IDLE;
                            else protocol_error <= 1;
                        end
                        4'h9: begin
                            if (armed && rx_full && csr_wdata == 32'(rx_sequence)) rx_full <= 0;
                            else protocol_error <= 1;
                        end
                        4'ha: begin
                            if (csr_wdata[31:2] != 0) protocol_error <= 1;
                            else begin
                                if (csr_wdata[0]) rx_abort_seen <= 0;
                                if (csr_wdata[1]) protocol_error <= 0;
                            end
                        end
                        default: protocol_error <= 1;
                    endcase
                end
                if (rx_aborted) rx_abort_seen <= 1; // Event wins concurrent W1C.
                if (rx_valid && rx_ready) begin
                    rx_byte <= rx_data;
                    rx_errors <= rx_error;
                    rx_full <= 1;
                    rx_sequence <= rx_sequence + 1'b1;
                end
                if (tx_state == TX_QUEUED) begin
                    if (cancel_queued) begin
                        tx_state <= TX_EVENT;
                        delivered <= 0;
                    end else if (tx_ready) tx_state <= TX_ACTIVE;
                end
                if (tx_done || tx_aborted) begin
                    if (tx_state == TX_ACTIVE) begin
                        tx_state <= TX_EVENT;
                        delivered <= tx_done && !tx_aborted;
                    end else protocol_error <= 1;
                    if (tx_done && tx_aborted) protocol_error <= 1;
                end
            end
        end
    end
endmodule
`default_nettype wire
