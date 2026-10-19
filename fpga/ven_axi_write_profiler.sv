`timescale 1ns/1ps
`default_nettype none

// Passive, single-outstanding-write latency accounting for the DDRAM-to-AXI
// bridge.  It observes only accepted outer-AXI handshakes; no output from this
// block participates in request, response, reset, cache, or CPU control.
//
// Counter definitions (all modulo 2^32):
//   * busy_cycles counts from the cycle after the first accepted AW or final-W
//     handshake through the accepted B response, inclusive of that B cycle.
//   * bwait_cycles counts the subset after both AW and WLAST have been
//     accepted, through the accepted B response.  This separates command
//     channel contention from response latency.
//   * bresp_error_count counts non-OKAY B handshakes.  It is observational;
//     error containment remains the responsibility of the transport bridge.
//
// ven_ddram_axi currently permits at most one outer write transaction.  The
// state recorder deliberately makes that assumption explicit rather than
// summing lifetimes of overlapping transactions and calling the result a
// latency.  It accepts AW/W skew (including W-before-AW) because AXI permits
// the channels to complete independently.
module ven_axi_write_profiler (
    input  wire        clk,
    input  wire        rst,
    input  wire        aw_handshake,
    input  wire        wlast_handshake,
    input  wire        b_handshake,
    input  wire [1:0]  bresp,
    output reg  [31:0] busy_cycles,
    output reg  [31:0] bwait_cycles,
    output reg  [31:0] bresp_error_count
);
    reg write_active;
    reg aw_seen;
    reg wlast_seen;

    always @(posedge clk) begin
        if (rst) begin
            busy_cycles      <= 32'd0;
            bwait_cycles     <= 32'd0;
            bresp_error_count<= 32'd0;
            write_active     <= 1'b0;
            aw_seen          <= 1'b0;
            wlast_seen       <= 1'b0;
        end else begin
            // Count the pre-edge lifetime so the final B handshake is included
            // and a legal zero-latency AW/W/B test contributes zero cycles.
            if (write_active) begin
                busy_cycles <= busy_cycles + 32'd1;
                if (aw_seen && wlast_seen)
                    bwait_cycles <= bwait_cycles + 32'd1;
            end

            if (b_handshake && (bresp != 2'b00))
                bresp_error_count <= bresp_error_count + 32'd1;

            // A B completion wins on a same-edge event: it closes the observed
            // transaction and leaves the recorder cleanly re-armed.  The real
            // bridge cannot create a new outer write in that same cycle.
            if (b_handshake) begin
                write_active <= 1'b0;
                aw_seen      <= 1'b0;
                wlast_seen   <= 1'b0;
            end else if (!write_active && (aw_handshake || wlast_handshake)) begin
                write_active <= 1'b1;
                aw_seen      <= aw_handshake;
                wlast_seen   <= wlast_handshake;
            end else if (write_active) begin
                if (aw_handshake)    aw_seen    <= 1'b1;
                if (wlast_handshake) wlast_seen <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
