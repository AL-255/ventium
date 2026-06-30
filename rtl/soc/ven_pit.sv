// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// ven_pit.sv -- Intel 8254 Programmable Interval Timer (PIT) for the Ventium SoC
//
// Standalone, synthesizable PC-peripheral device modeling the CPU-observable
// register behavior of QEMU 8.2.2's hw/timer/i8254.c (+ i8254_common.c). It is
// SELF-CONTAINED: depends on no package and no other RTL. Intended to be wired
// uniformly under the future ventium_soc PMIO decoder (cs/we/addr/wdata/rdata).
//
// Ports (PMIO common interface):
//   I/O ports 0x40 (ch0), 0x41 (ch1), 0x42 (ch2), 0x43 (mode/command, write-only)
//   addr[1:0] selects channel / command (addr & 3, matching QEMU); the decoder
//   asserts `cs` for any of 0x40..0x43 hitting this device.
//   Channel 0 OUT is exported as `out0`, the IRQ0 source.
//
// ---------------------------------------------------------------------------
// FREE-RUNNING COUNT / clk -> PIT_FREQ RELATIONSHIP  (documented model)
// ---------------------------------------------------------------------------
// QEMU computes the elapsed count from virtual wall-clock nanoseconds:
//     d = muldiv64(now_ns - count_load_time_ns, PIT_FREQ, 1e9)
// i.e. `d` is the number of 1193182 Hz PIT ticks since the channel's count was
// last (re)loaded. The live count and the OUT bit are pure functions of d.
//
// In hardware there is no wall clock; we model `d` with a free-running per-
// channel tick counter `d_q[ch]` that increments once per PIT tick and resets
// to 0 when that channel's count is (re)loaded. A PIT tick is produced from the
// module clock `clk` by a parameterized prescaler:
//
//     CLK_HZ / TICK_DIV  ==  PIT_FREQ (1193182 Hz)   [nominal]
//
//   * TICK_DIV == 1 (default): one PIT tick PER clk edge. The host drives this
//     module with a 1.193182 MHz clock (the real 8254 PCLK), so `clk` IS the
//     PIT clock. This is the natural SoC wiring and what the unit TB uses --
//     it makes the elapsed-tick math exact and oracle-checkable.
//   * TICK_DIV > 1: divide a faster `clk` down to the PIT rate. A 24-bit
//     accumulator (TICK_INC/TICK_DIV ratio) generates tick enables; the exact
//     cadence then depends on CLK_HZ and is STRUCTURAL, NOT oracled (see notes).
//
// CYCLE-EXACT CADENCE IS STRUCTURAL, NOT ORACLED: the *register* semantics
// (what the CPU reads/writes, the control/read-back state machines, latching,
// the OUT formula vs count) are matched bit-exactly to QEMU and self-checked.
// The precise clk-cycle at which a given tick falls (and hence the precise
// real-time edge of OUT/IRQ0) is a structural property of the prescaler, not
// something the unit self-check oracles against QEMU's ns timeline.
// ============================================================================

module ven_pit #(
    // Prescaler from clk to the 1193182 Hz PIT tick. Default: clk == PIT clock.
    parameter int unsigned TICK_DIV = 1,
    parameter int unsigned TICK_INC = 1
) (
    input  logic        clk,        // module clock (PIT PCLK when TICK_DIV==1)
    input  logic        rst,        // synchronous, ACTIVE-HIGH (PC RESET)

    // PMIO common register interface
    input  logic        cs,         // chip-select (decoder: port in 0x40..0x43)
    input  logic        we,         // 1 = OUT (CPU write), 0 = IN (CPU read)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] addr,       // I/O port; only addr[1:0] select the register
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [7:0]  wdata,      // CPU write data
    output logic [7:0]  rdata,      // CPU read data (combinational off regs)

    // device outputs
    output logic        out0        // ch0 OUT pin == the IRQ0 line
);

    // ---- RW_STATE encodings (match i8254.c) -------------------------------
    localparam logic [2:0] RW_MSB   = 3'd2;
    localparam logic [2:0] RW_WORD0 = 3'd3;
    localparam logic [2:0] RW_WORD1 = 3'd4;

    // ---- Per-channel architectural state ----------------------------------
    // count can be 0x10000 -> needs 17 bits.
    logic [16:0] count_q       [3];   // current programmed count (1..0x10000)
    logic [15:0] latched_count [3];   // snapshot taken by latch-count
    logic [2:0]  count_latched [3];   // 0=not latched, else RW_* sub-state
    logic        status_latched[3];
    logic [7:0]  status_q      [3];   // latched status byte
    logic [2:0]  read_state    [3];   // RW_LSB/MSB/WORD0/WORD1
    logic [2:0]  write_state   [3];
    logic [7:0]  write_latch   [3];   // low byte held between WORD0 writes
    logic [2:0]  rw_mode       [3];   // access mode 1..3 (LSB/MSB/WORD)
    logic [2:0]  mode_q        [3];   // operating mode 0..5 (7 wraps to 5)
    logic        bcd_q         [3];

    // NOTE: the real 8254 has a GATE input per channel (resets to 1 for ch0/ch1,
    // 0 for ch2) that arms/restarts counting. No SoC GATE port is exposed here:
    // ch0 (IRQ0) is permanently gated on, which is its boot/Win95 configuration.
    // GATE-driven restart is DEFERRED (see honest notes).

    // Free-running elapsed-PIT-ticks since last count load (models QEMU `d`).
    // 32 bits is ample headroom over the 17-bit count.
    logic [31:0] d_q           [3];

    // SINGLE maintained per-channel modulo remainder  dmod1_q == d_q % count_q,
    // advanced incrementally each tick (ALWAYS step +1, mode-independent) so the
    // module needs NO hardware divider at all. Both divide-using helpers derive
    // their value from this one register with only a shift / compare / subtract:
    //   * f_get_count mode 2:  count - dmod1_q                 (== count - d%count)
    //   * f_get_count mode 3:  count - ((2*dmod1_q) mod count) (2*d%count via 1 sub)
    //   * f_get_out   mode 2:  (dmod1_q==0) && (d!=0)
    //   * f_get_out   mode 3:  dmod1_q < (count+1)>>1
    // Keeping ONE remainder ( d%count, not the mode-3-specific 2d%count ) lets the
    // mode-3 OUT bit (status_q[7], the old top board path) reuse it -- it needs
    // d%count, which 2d%count could not supply. For modes 0/1/4/5 the remainder is
    // unused (those use count-d / d-vs-count directly), so the +1 advance is
    // harmless. dmod1_q < count_q (<= 0x10000) so it fits in 16 bits; the advance
    // compare/wrap is done at 17 bits to be safe at the count==0x10000 boundary.
    // dmod1_q is held in PERFECT lock-step with d_q: zeroed in EVERY place d_q is
    // zeroed (reset + every count load), plus on a bare control-word (mode/access)
    // write so a mode change without a reload restarts the remainder at 0.
    logic [15:0] dmod1_q       [3];

    // PIT tick enable (one PIT tick per asserted cycle).
    logic        tick_en;

    // ------------------------------------------------------------------------
    // PIT tick generation
    // ------------------------------------------------------------------------
    generate
        if (TICK_DIV <= 1) begin : g_tick_1to1
            assign tick_en = 1'b1;            // one PIT tick per clk
        end else begin : g_tick_div
            // Fractional accumulator: add TICK_INC each clk, emit a tick and
            // subtract TICK_DIV when the accumulator reaches the threshold.
            logic [23:0] tick_acc_q;
            logic [24:0] acc_next;
            assign acc_next = {1'b0, tick_acc_q} + 25'(TICK_INC);
            assign tick_en  = (acc_next >= 25'(TICK_DIV));
            always_ff @(posedge clk) begin
                if (rst)
                    tick_acc_q <= '0;
                else if (tick_en)
                    tick_acc_q <= 24'(acc_next - 25'(TICK_DIV));
                else
                    tick_acc_q <= acc_next[23:0];
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Combinational helpers (mirror pit_get_count / pit_get_out)
    // ------------------------------------------------------------------------
    // pit_get_count: live count given elapsed ticks d, count c, mode m.
    // Performs NO hardware divide. dmod1 is the single maintained remainder
    // (d % count). Modes 0/1/4/5 use count - d (mod 65536); mode 2 uses
    // count - dmod1; mode 3 needs (2*d) % count, derived from dmod1 by one
    // conditional subtract of count: since dmod1 < count, 2*dmod1 < 2*count, so
    //   r3 = (2*dmod1 >= count) ? 2*dmod1 - count : 2*dmod1
    // is exact ( == (2*d) % count ). The compare/subtract is at 17 bits because
    // 2*dmod1 can reach ~2*0x10000; c17 is the full 17-bit count for that path.
    // d is passed low-16 only (the count-minus-d subtraction is mod 65536, so
    // d[31:16] never affects it).
    function automatic logic [15:0] f_get_count(input logic [2:0]  m,
                                                input logic [16:0] c17,
                                                input logic [15:0] d,
                                                input logic [15:0] dmod1);
        logic [16:0] twor;       // 2*dmod1, 17b
        logic [15:0] r3;         // (2*d) % count (always < count <= 0x10000 -> 16b)
        begin
            twor = {dmod1, 1'b0};                                 // 2*dmod1 (17b)
            // (2*d) % count : since dmod1 < count, 2*dmod1 < 2*count, one subtract.
            r3   = (twor >= c17) ? (twor[15:0] - c17[15:0]) : twor[15:0];
            unique case (m)
                3'd0, 3'd1, 3'd4, 3'd5:
                    f_get_count = c17[15:0] - d;                  // (count - d) & 0xffff
                3'd3:
                    f_get_count = c17[15:0] - r3;                 // count - ((2*d)%count)
                default:                                          // mode 2 (and 6/7)
                    f_get_count = c17[15:0] - dmod1;              // count - (d % count)
            endcase
        end
    endfunction

    // pit_get_out: OUT bit given elapsed ticks d, count c, mode m. Performs NO
    // hardware divide -- modes 2 and 3 reuse the single maintained remainder
    // dmod1 (== d % count). Mode 2 (rate gen): OUT high only on the terminal tick
    // (dmod1==0 with d!=0). Mode 3 (square wave): OUT high for the first half of
    // the period (dmod1 < (count+1)>>1). Modes 4/5 (strobe) and 0/1 compare d to
    // count directly (no modulo).
    function automatic logic f_get_out(input logic [2:0]  m,
                                       input logic [16:0] c,
                                       input logic [31:0] d,
                                       input logic [15:0] dmod1);
        logic [16:0] half;       // (count+1)>>1
        begin
            half = 17'((c + 17'd1) >> 1);
            unique case (m)
                3'd2:                                             // rate generator
                    f_get_out = (dmod1 == 16'd0) && (d != 32'd0);
                3'd3:                                             // square wave
                    f_get_out = ({1'b0, dmod1} < half);
                3'd4, 3'd5:                                       // strobe
                    f_get_out = (d == {15'b0, c});
                default:                                          // mode 0,1
                    f_get_out = (d >= {15'b0, c});
            endcase
        end
    endfunction

    // ------------------------------------------------------------------------
    // Decoded request
    // ------------------------------------------------------------------------
    logic [1:0] sel;                 // addr & 3 (QEMU masks the I/O port to 2 bits)
    assign sel = addr[1:0];

    // Control-word write fields (only meaningful when sel==3 && we)
    logic [1:0] cw_channel;          // wdata[7:6]
    logic [1:0] cw_access;           // wdata[5:4]
    logic [2:0] cw_mode;             // wdata[3:1]
    logic       cw_bcd;             // wdata[0]
    assign cw_channel = wdata[7:6];
    assign cw_access  = wdata[5:4];
    assign cw_mode    = wdata[3:1];
    assign cw_bcd     = wdata[0];

    // ------------------------------------------------------------------------
    // COMBINATIONAL READ (rdata) -- pure function of current register state.
    // Read SIDE-EFFECTS (advancing read_state / clearing latches) are applied
    // on the clocked edge below. Reading 0x43 returns 0 (write-only).
    // ------------------------------------------------------------------------
    function automatic logic [7:0] f_read(input logic [1:0] s);
        logic [15:0] lc;
        logic [15:0] live;
        begin
            f_read = 8'h00;
            if (s != 2'd3) begin
                lc   = latched_count[s];
                live = f_get_count(mode_q[s], count_q[s], d_q[s][15:0], dmod1_q[s]);
                if (status_latched[s]) begin
                    f_read = status_q[s];
                end else if (count_latched[s] != 3'd0) begin
                    unique case (count_latched[s])
                        RW_MSB:   f_read = lc[15:8];
                        RW_WORD0: f_read = lc[7:0];
                        default:  f_read = lc[7:0];               // RW_LSB
                    endcase
                end else begin
                    unique case (read_state[s])
                        RW_MSB:   f_read = live[15:8];
                        RW_WORD1: f_read = live[15:8];
                        default:  f_read = live[7:0];             // LSB / WORD0
                    endcase
                end
            end
        end
    endfunction

    always_comb begin
        rdata = f_read(sel);
    end

    // pit_load_count: a write value of 0 means a full 0x10000 count.
    function automatic logic [16:0] f_loadval(input logic [15:0] v);
        f_loadval = (v == 16'd0) ? 17'h1_0000 : {1'b0, v};
    endfunction

    // ------------------------------------------------------------------------
    // OUT pin (ch0) -- combinational off architectural state.
    // ------------------------------------------------------------------------
    assign out0 = f_get_out(mode_q[0], count_q[0], d_q[0], dmod1_q[0]);

    // ------------------------------------------------------------------------
    // CLOCKED state update
    // ------------------------------------------------------------------------
    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            // pit_reset_common: mode=3, gate=(i!=2), count=0x10000, d=0.
            // The non-reset register fields (read/write state etc.) power up 0
            // in QEMU's zero-initialized device state; match that.
            for (i = 0; i < 3; i = i + 1) begin
                count_q[i]        <= 17'h1_0000;
                latched_count[i]  <= 16'h0000;
                count_latched[i]  <= 3'd0;
                status_latched[i] <= 1'b0;
                status_q[i]       <= 8'h00;
                read_state[i]     <= 3'd0;
                write_state[i]    <= 3'd0;
                write_latch[i]    <= 8'h00;
                rw_mode[i]        <= 3'd0;
                mode_q[i]         <= 3'd3;
                bcd_q[i]          <= 1'b0;
                d_q[i]            <= 32'd0;
                dmod1_q[i]        <= 16'h0000;   // lock-step with d_q reset
            end
        end else begin
            // ---- free-running tick: advance each channel's elapsed count ----
            // Also advance the single maintained remainder dmod1_q[i] == d%count in
            // lock-step so NO divider is ever needed: ALWAYS +1, wrap to 0 when it
            // would REACH count (mode-independent -- modes 2/3 derive their value
            // from this one register, see f_get_count/f_get_out; modes 0/1/4/5 do
            // not read it). The compare/wrap is at 17 bits (count_q is [0..0x10000])
            // to be safe at the count==0x10000 boundary; dmod1_q stays < count_q so
            // 16 bits hold it.
            if (tick_en) begin
                for (i = 0; i < 3; i = i + 1) begin
                    d_q[i] <= d_q[i] + 32'd1;
                    // d % count : add 1, wrap to 0 when it would reach count.
                    if (({1'b0, dmod1_q[i]} + 17'd1) >= count_q[i])
                        dmod1_q[i] <= 16'd0;
                    else
                        dmod1_q[i] <= dmod1_q[i] + 16'd1;
                end
            end

            // ---- CPU register access (one transaction per cs cycle) --------
            if (cs && we) begin
                // -------------------- WRITE (OUT) --------------------------
                if (sel == 2'd3) begin
                    // ---- 0x43 control / read-back command ----
                    if (cw_channel == 2'd3) begin
                        // read-back command: act on channels selected by
                        // bit (2<<ch) of wdata.
                        for (i = 0; i < 3; i = i + 1) begin
                            if (wdata[1 + i]) begin               // 2<<channel
                                if (!wdata[5]) begin              // !bit5: latch count
                                    if (count_latched[i] == 3'd0) begin
                                        latched_count[i] <= f_get_count(mode_q[i], count_q[i], d_q[i][15:0], dmod1_q[i]);
                                        count_latched[i] <= rw_mode[i];
                                    end
                                end
                                if (!wdata[4] && !status_latched[i]) begin // !bit4: latch status
                                    status_q[i] <= { f_get_out(mode_q[i], count_q[i], d_q[i], dmod1_q[i]),
                                                     1'b0,                 // null count (XXX not modeled)
                                                     rw_mode[i][1:0],
                                                     mode_q[i],
                                                     bcd_q[i] };
                                    status_latched[i] <= 1'b1;
                                end
                            end
                        end
                    end else begin
                        // ---- per-channel control word ----
                        if (cw_access == 2'd0) begin
                            // counter-latch command (access==0)
                            if (count_latched[cw_channel] == 3'd0) begin
                                latched_count[cw_channel] <= f_get_count(mode_q[cw_channel],
                                                                          count_q[cw_channel],
                                                                          d_q[cw_channel][15:0],
                                                                          dmod1_q[cw_channel]);
                                count_latched[cw_channel] <= rw_mode[cw_channel];
                            end
                        end else begin
                            rw_mode[cw_channel]     <= {1'b0, cw_access};
                            read_state[cw_channel]  <= {1'b0, cw_access};
                            write_state[cw_channel] <= {1'b0, cw_access};
                            mode_q[cw_channel]      <= cw_mode;
                            bcd_q[cw_channel]       <= cw_bcd;
                            // A bare control word sets the mode but (like QEMU) does
                            // NOT reset d_q. dmod1_q (== d%count) is mode-independent
                            // now, but a count read between a bare mode write and the
                            // eventual reload is non-architectural (QEMU reloads too);
                            // restarting the remainder at 0 here keeps it consistent
                            // with the standard guest sequence (control word THEN a
                            // count load, which re-zeros both d_q and dmod1_q).
                            dmod1_q[cw_channel]     <= 16'h0000;
                        end
                    end
                end else begin
                    // ---- 0x40/0x41/0x42 data write: load count per write_state ----
                    unique case (write_state[sel])
                        RW_MSB: begin
                            count_q[sel] <= f_loadval({wdata, 8'h00});  // val<<8
                            d_q[sel]     <= 32'd0;
                            dmod1_q[sel] <= 16'h0000;   // lock-step with d_q load
                        end
                        RW_WORD0: begin
                            write_latch[sel]  <= wdata;
                            write_state[sel]  <= RW_WORD1;
                        end
                        RW_WORD1: begin
                            count_q[sel] <= f_loadval({wdata, write_latch[sel]});
                            d_q[sel]     <= 32'd0;
                            dmod1_q[sel] <= 16'h0000;   // lock-step with d_q load
                            write_state[sel] <= RW_WORD0;
                        end
                        default: begin                            // RW_LSB
                            count_q[sel] <= f_loadval({8'h00, wdata});
                            d_q[sel]     <= 32'd0;
                            dmod1_q[sel] <= 16'h0000;   // lock-step with d_q load
                        end
                    endcase
                end
            end else if (cs && !we) begin
                // -------------------- READ (IN) side-effects ----------------
                // 0x43 read is ignored (write-only) -> no side effects.
                if (sel != 2'd3) begin
                    if (status_latched[sel]) begin
                        status_latched[sel] <= 1'b0;
                    end else if (count_latched[sel] != 3'd0) begin
                        unique case (count_latched[sel])
                            RW_WORD0: count_latched[sel] <= RW_MSB;   // LSB done, MSB next
                            default:  count_latched[sel] <= 3'd0;     // LSB / MSB: clear
                        endcase
                    end else begin
                        unique case (read_state[sel])
                            RW_WORD0: read_state[sel] <= RW_WORD1;
                            RW_WORD1: read_state[sel] <= RW_WORD0;
                            default: ; // LSB / MSB: no change
                        endcase
                    end
                end
            end
        end
    end

endmodule
