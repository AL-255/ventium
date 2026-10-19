`default_nettype none

// Passive, single-outstanding-read latency accounting for the DDRAM-to-AXI
// bridge.  It intentionally observes only handshakes: no signal from this
// block feeds the AXI master, cache, CPU, or reset path.
//
// Counter definitions (all are modulo 2^32):
//   * busy_cycles counts core-clock cycles from just after an accepted AR
//     through the accepted RLAST beat, inclusive of that final beat.
//   * first_wait_cycles is the corresponding prefix through the first
//     accepted R beat, inclusive of that beat.
// Given externally counted AR transactions and accepted R beats, the number
// of bubble cycles between accepted R beats is:
//   busy_cycles - first_wait_cycles - (read_beats - read_transactions)
// (with an all-zero latency transaction clamped to zero by the consumer).
//
// ven_ddram_axi permits one read transaction at a time.  Keeping that
// invariant explicit here makes the measurement meaningful and avoids
// pretending that a sum of overlapping request lifetimes is a latency.
module ven_axi_read_profiler (
    input  wire        clk,
    input  wire        rst,
    input  wire        ar_handshake,
    input  wire        r_handshake,
    input  wire        r_last,
    output reg [31:0] busy_cycles,
    output reg [31:0] first_wait_cycles
);
    reg read_active;
    reg awaiting_first;

    always @(posedge clk) begin
        if (rst) begin
            busy_cycles       <= 32'd0;
            first_wait_cycles <= 32'd0;
            read_active       <= 1'b0;
            awaiting_first    <= 1'b0;
        end else begin
            if (read_active) begin
                busy_cycles <= busy_cycles + 32'd1;
                if (awaiting_first)
                    first_wait_cycles <= first_wait_cycles + 32'd1;
            end

            // The bridge has at most one outer read outstanding.  A same-cycle
            // AR/R completion remains well-defined for a zero-latency test
            // slave: the RLAST assignment below wins and neither time counter
            // advances, as it should.
            if (ar_handshake) begin
                read_active    <= 1'b1;
                awaiting_first <= 1'b1;
            end
            if (r_handshake) begin
                awaiting_first <= 1'b0;
                if (r_last)
                    read_active <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
