// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// biu_p5.sv  --  Ventium M5B: pin-level 64-bit external Bus Interface Unit
//
// Self-contained replica of the Intel Pentium (P5/P54C) external bus FSM, per
// datasheet 241997-010 Table 2 (Quick Pin Reference) and section 3 (Bus
// Functional Description), and Developer's Manual Vol.1 (241428-004) Ch.6 /
// Table 6-12 (burst order).
//
// ISOLATION: this module is fully standalone. It declares its OWN localparams
// and does NOT import ventium_pkg, never references rtl/. Verified only by SVA
// protocol invariants + a directed self-consistency testbench (no-oracle/M2S).
//
// Active-low bus signals use the _n suffix (asserted == logic 0).
// All synchronous logic is referenced to the rising edge of clk; reset is
// synchronous active-high.
//
// Phase-3 corrections applied (see docs/m5b-bus-spec.md and the in-line tags
// [FIX-n]): NA#/last-BRDY# race, INV-independent HITM#/writeback, two-cycle
// BOFF# save/restart, burst-behind-pipeline guard, Table 6-12 burst order with
// the address driven once and held, HITM# released only by the actual
// writeback, SCYC only for misaligned >2-cycle locked groups, no fresh ADS#
// while AHOLD floats the address bus, write data driven from T2, HOLD honored
// during reset.
// ============================================================================
`default_nettype none

module biu_p5 (
    input  wire        clk,
    input  wire        reset,          // synchronous, active high (RESET)

    // ----- core-side request interface (we define this; see m5b-bus-spec.md) -
    input  wire        req,            // core wants a bus cycle
    input  wire        req_we,         // 1 = write, 0 = read
    input  wire        req_cache,      // 1 = cacheable (drives CACHE#)
    input  wire        req_lock,       // 1 = locked cycle (drives LOCK#)
    input  wire        req_split,      // 1 = misaligned/>2-cycle locked group (drives SCYC)
    input  wire        req_mio,        // M/IO# value
    input  wire        req_dc,         // D/C# value
    input  wire [28:0] req_addr,       // A31..A3
    input  wire [7:0]  req_be,         // BE7..BE0 (active high to core)
    input  wire [63:0] req_wdata,      // write data (single) / first WB beat
    input  wire        req_wb,          // 1 = this write IS the snoop-hit writeback
    output reg         req_ack,        // 1-clk: request accepted (ADS# issued)
    output reg         rsp_valid,      // 1-clk per returned beat
    output reg [63:0]  rsp_data,       // read data for the current beat
    output reg         rsp_last,       // 1 on final beat of the cycle
    output reg         wb_req,         // snoop hit-modified => writeback needed

    // ----- external bus: address / cycle definition (driven with ADS#) ------
    output reg         adsn,           // ADS#  (O, active low)
    output reg [28:0]  a,              // A31..A3 (O when a_oe)
    output reg         a_oe,           // address-bus output enable
    output reg [7:0]   be_n,           // BE7#..BE0# (O, active low)
    output reg         mion,           // M/IO#
    output reg         dcn,            // D/C#
    output reg         wrn,            // W/R#
    output reg         cachen,         // CACHE# (O, active low)
    output reg         scycn,          // SCYC   (O, active low)
    output reg         lockn,          // LOCK#  (O, active low)

    // ----- external bus: data / completion ----------------------------------
    output reg [63:0]  d_out,          // D63..D0 write data
    output reg         d_oe,           // data-bus output enable (1 => BIU drives)
    input  wire [63:0] d_in,           // D63..D0 read data
    input  wire        brdyn,          // BRDY#  (I, active low) burst ready
    input  wire        nan,            // NA#    (I, active low) next address
    input  wire        kenn,           // KEN#   (I, active low) cache enable

    // ----- external bus: arbitration ----------------------------------------
    input  wire        hold,           // HOLD   (I, active high)
    output reg         hlda,           // HLDA   (O, active high)
    input  wire        boffn,          // BOFF#  (I, active low) backoff
    output reg         breq,           // BREQ   (O, active high)

    // ----- external bus: inquire / snoop ------------------------------------
    input  wire        ahold,          // AHOLD  (I, active high) address hold
    input  wire        eadsn,          // EADS#  (I, active low) snoop addr valid
    input  wire        inv,            // INV    (I, active high) -> I else S
    input  wire [26:0] a_in,           // A31..A5 inquire address (input)
    output reg         hitn,           // HIT#   (O, active low)
    output reg         hitmn,          // HITM#  (O, active low)

    // ----- debug/observability (for SVA + self-consistency testbench) -------
    output wire [2:0]  dbg_state,      // current data-FSM state
    output wire        dbg_is_burst,   // current cycle qualified as a burst
    output wire [1:0]  dbg_outstanding,// outstanding-cycle count
    output wire        dbg_pipe_burst, // older cycle in T2P is a burst
    output wire        dbg_inv_state,  // post-snoop final state bit (1=I, 0=S)
    output wire [1:0]  dbg_snoop_state // current snoop-tracker state
);

  // ---------------------------------------------------------------------------
  // Local parameters (NO ventium_pkg import -- fully standalone)
  // ---------------------------------------------------------------------------
  localparam [2:0] S_IDLE  = 3'd0;  // bus idle, no cycle outstanding
  localparam [2:0] S_T1    = 3'd1;  // address status: ADS# asserted (1 clock)
  localparam [2:0] S_T2    = 3'd2;  // data: wait BRDY# / sample NA#/KEN#
  localparam [2:0] S_T12   = 3'd3;  // pipelined: ADS# of 2nd cycle while 1st outstanding
  localparam [2:0] S_T2P   = 3'd4;  // two cycles outstanding, completing 1st
  localparam [2:0] S_BOFF  = 3'd5;  // backed off (floating, aborted)
  localparam [2:0] S_HOLD  = 3'd6;  // bus granted to another master (HLDA asserted)

  localparam [1:0] SN_IDLE = 2'd0;  // snoop tracker idle
  localparam [1:0] SN_S1   = 2'd1;  // 1 clock after EADS#
  localparam [1:0] SN_S2   = 2'd2;  // 2 clocks after EADS#: drive HIT#/HITM#

  localparam [2:0] BURST_BEATS  = 3'd4;   // 32-byte line / 8 bytes = 4 beats
  localparam [2:0] SINGLE_BEATS = 3'd1;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  reg [2:0]  st;
  reg [1:0]  sn_st;

  // current cycle attributes (latched at ADS#)
  reg        cyc_we;
  reg        cyc_cache;
  reg [28:0] cyc_addr;          // A31..A3 ; A4..A3 advances during a burst
  reg [7:0]  cyc_be;
  reg [63:0] cyc_wdata;
  reg        cyc_wb;            // current cycle is the snoop-hit writeback
  reg [2:0]  beats_left;        // beats remaining to terminate the current cycle
  reg        is_burst;          // current cycle is a 4-beat line fill
  reg        burst_q_done;      // KEN#/CACHE# already qualified this cycle
  reg [1:0]  burst_base;        // A[4:3] of the line-fill first transfer
  reg [1:0]  burst_idx;         // which transfer (0..3) of the burst order

  // pipelined (2nd) cycle attributes
  reg        p_valid;           // a 2nd cycle is queued/outstanding
  reg        p_we, p_cache, p_mio, p_dc, p_lock, p_split, p_wb;
  reg [28:0] p_addr;
  reg [7:0]  p_be;
  reg [63:0] p_wdata;

  // outstanding-cycle accounting (for SVA P4 / P3)
  reg [1:0]  outstanding;

  // locked group tracking
  reg        lock_active;       // a locked group is in progress (drives LOCK#)

  // backoff save/restore: remember the cycle(s) that were aborted.
  // [FIX-3] BOFF# can abort up to TWO outstanding cycles (current + pipelined).
  // We save BOTH and replay them in order (older first, then the pipelined one).
  reg        boff_pending;      // >=1 cycle must be restarted after BOFF# negates
  reg        bsv_we, bsv_cache, bsv_mio, bsv_dc, bsv_lock, bsv_split, bsv_wb;
  reg [28:0] bsv_addr;
  reg [7:0]  bsv_be;
  reg [63:0] bsv_wdata;
  reg        bsv_is_burst;      // older saved cycle was a burst
  reg [2:0]  bsv_beats;         // beats remaining on the older saved cycle
  reg [1:0]  bsv_base, bsv_idx; // burst position of the older saved cycle
  reg        bsv2_valid;        // a SECOND (pipelined) cycle was also outstanding
  reg        bsv2_we, bsv2_cache, bsv2_mio, bsv2_dc, bsv2_lock, bsv2_split, bsv2_wb;
  reg [28:0] bsv2_addr;
  reg [7:0]  bsv2_be;
  reg [63:0] bsv2_wdata;

  // snoop result
  reg        snoop_hit;
  reg        snoop_mod;         // hit to a modified line (independent of INV)
  reg        snoop_inv;         // captured INV: 1 => final state I, 0 => final state S

  // helper combinational
  // HOLD recognized when not in a locked group (datasheet: not recognized during
  // LOCK#) but IS recognized during reset.
  wire grant_hold = hold && !lock_active && (st == S_IDLE) && !req && !boff_pending;

  // observability outputs
  assign dbg_state       = st;
  assign dbg_is_burst    = is_burst;
  assign dbg_outstanding = outstanding;
  assign dbg_pipe_burst  = is_burst;     // in T2P the "older" current cycle is `is_burst`
  assign dbg_inv_state   = snoop_inv;
  assign dbg_snoop_state = sn_st;

  // ---------------------------------------------------------------------------
  // Combinational helpers (functions of registered state)
  // ---------------------------------------------------------------------------
  // beats remaining including the upgrade-to-burst that may happen this clock
  function automatic [2:0] effective_beats;
    if (!burst_q_done && cyc_cache && !kenn && !cyc_we)
      effective_beats = BURST_BEATS;
    else
      effective_beats = beats_left;
  endfunction

  // [FIX-4] a burst (multi-beat) current cycle must NOT be pipelined behind:
  // T2P only handles single-beat older cycles, so block accepting a 2nd cycle
  // while the current one is (or is about to become) a burst.
  function automatic logic cyc_blocks_pipe;
    cyc_blocks_pipe = is_burst ||
                      (!burst_q_done && cyc_cache && !kenn && !cyc_we);
  endfunction

  // locked group considered "done" when this is the write (2nd) of an RMW pair
  function automatic logic lock_group_done;
    lock_group_done = cyc_we; // read first (not done), write second (done)
  endfunction

  // [FIX-5] Pentium burst order, Table 6-12 (Dev Manual Vol.1). Two-bank
  // optimized. Given the line-fill base A[4:3] and the transfer index 0..3,
  // return the A[4:3] of that transfer. The address is computed here only to
  // *model* the line; the pins are NOT re-driven (a_oe drops to 0 after T1 of a
  // burst -- see the FSM). burst order rows:
  //   base 0 : 0 1 2 3   |  base 1 : 1 0 3 2
  //   base 2 : 2 3 0 1   |  base 3 : 3 2 1 0
  function automatic [1:0] burst_addr;
    input [1:0] base;
    input [1:0] idx;
    burst_addr = base ^ idx;   // XOR yields exactly the Table 6-12 sequence
  endfunction

  // ---------------------------------------------------------------------------
  // Main FSM
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    // default single-clock strobes
    req_ack   <= 1'b0;
    rsp_valid <= 1'b0;
    rsp_last  <= 1'b0;

    if (reset) begin
      st           <= S_IDLE;
      sn_st        <= SN_IDLE;
      adsn         <= 1'b1;
      a            <= 29'd0;
      a_oe         <= 1'b0;     // bus inactive after reset
      be_n         <= 8'hFF;
      mion         <= 1'b1;
      dcn          <= 1'b1;
      wrn          <= 1'b1;
      cachen       <= 1'b1;
      scycn        <= 1'b1;
      lockn        <= 1'b1;
      d_out        <= 64'd0;
      d_oe         <= 1'b0;
      breq         <= 1'b0;
      hitn         <= 1'b1;
      hitmn        <= 1'b1;
      rsp_data     <= 64'd0;
      wb_req       <= 1'b0;
      cyc_we       <= 1'b0;
      cyc_cache    <= 1'b0;
      cyc_addr     <= 29'd0;
      cyc_be       <= 8'h00;
      cyc_wdata    <= 64'd0;
      cyc_wb       <= 1'b0;
      beats_left   <= 3'd0;
      is_burst     <= 1'b0;
      burst_q_done <= 1'b0;
      burst_base   <= 2'd0;
      burst_idx    <= 2'd0;
      p_valid      <= 1'b0;
      outstanding  <= 2'd0;
      lock_active  <= 1'b0;
      boff_pending <= 1'b0;
      bsv2_valid   <= 1'b0;
      snoop_hit    <= 1'b0;
      snoop_mod    <= 1'b0;
      snoop_inv    <= 1'b0;
      // [FIX-12] HOLD recognized during reset: HLDA may assert while RESET held.
      hlda         <= (hold) ? 1'b1 : 1'b0;
    end else begin
      // BREQ reflects an internal pending request at any time
      breq <= req | p_valid | boff_pending;

      // ----------------------------------------------------------------------
      // BOFF#: highest priority. On assertion, abort & float next clock.
      // ----------------------------------------------------------------------
      if (!boffn && st != S_BOFF && st != S_HOLD) begin
        // [FIX-3] save the in-flight cycle(s) for restart "in their entirety".
        if (st == S_T1 || st == S_T2 || st == S_T12 || st == S_T2P) begin
          boff_pending <= 1'b1;
          // older/current cycle
          bsv_we      <= cyc_we;
          bsv_cache   <= cyc_cache;
          bsv_mio     <= mion;
          bsv_dc      <= dcn;
          bsv_lock    <= lock_active;
          bsv_split   <= ~scycn;
          bsv_wb      <= cyc_wb;
          bsv_addr    <= cyc_addr;
          bsv_be      <= cyc_be;
          bsv_wdata   <= cyc_wdata;
          bsv_is_burst<= is_burst;
          bsv_beats   <= beats_left;
          bsv_base    <= burst_base;
          bsv_idx     <= burst_idx;
          // second (pipelined) cycle, if one is outstanding
          if (p_valid) begin
            bsv2_valid <= 1'b1;
            bsv2_we    <= p_we;
            bsv2_cache <= p_cache;
            bsv2_mio   <= p_mio;
            bsv2_dc    <= p_dc;
            bsv2_lock  <= p_lock;
            bsv2_split <= p_split;
            bsv2_wb    <= p_wb;
            bsv2_addr  <= p_addr;
            bsv2_be    <= p_be;
            bsv2_wdata <= p_wdata;
          end else begin
            bsv2_valid <= 1'b0;
          end
        end
        st          <= S_BOFF;
        adsn        <= 1'b1;
        a_oe        <= 1'b0;   // float address
        d_oe        <= 1'b0;   // float data
        outstanding <= 2'd0;
        p_valid     <= 1'b0;   // [FIX-3] clear live pipeline; restart owns replay
      end
      else begin
        case (st)
          // ------------------------------------------------------------------
          S_IDLE: begin
            // HOLD arbitration (only when idle and not locked)
            if (grant_hold) begin
              st   <= S_HOLD;
              hlda <= 1'b1;
              a_oe <= 1'b0;
              d_oe <= 1'b0;
              adsn <= 1'b1;
            end
            // [FIX-3] BOFF# replay: a re-queued 2nd cycle waiting in p_* is
            // launched from IDLE as a fresh, P3-legal ADS# (after the older
            // restarted cycle completed and returned here with p_valid set).
            else if (p_valid && !ahold) begin
              st        <= S_T1;
              adsn      <= 1'b0;
              a         <= p_addr;
              a_oe      <= 1'b1;
              be_n      <= ~p_be;
              mion      <= p_mio;
              dcn       <= p_dc;
              wrn       <= p_we;
              cachen    <= p_cache ? 1'b0 : 1'b1;
              scycn     <= (p_lock && p_split) ? 1'b0 : 1'b1;
              if (p_lock) begin
                lockn       <= 1'b0;
                lock_active <= 1'b1;
              end else begin
                lockn       <= lock_active ? 1'b0 : 1'b1;
              end
              cyc_we       <= p_we;
              cyc_cache    <= p_cache;
              cyc_addr     <= p_addr;
              cyc_be       <= p_be;
              cyc_wdata    <= p_wdata;
              cyc_wb       <= p_wb;
              burst_q_done <= 1'b0;
              is_burst     <= 1'b0;
              burst_base   <= p_addr[1:0];
              burst_idx    <= 2'd0;
              beats_left   <= SINGLE_BEATS;
              d_out        <= p_wdata;
              d_oe         <= 1'b0;
              outstanding  <= 2'd1;
              p_valid      <= 1'b0;
              req_ack      <= 1'b1;
            end
            else if (req && !ahold) begin  // [FIX-8] no new ADS# while AHOLD floats addr
              // launch a new cycle: enter T1, drive ADS# + cycle definition
              st        <= S_T1;
              adsn      <= 1'b0;          // ADS# asserted (one clock)
              a         <= req_addr;
              a_oe      <= 1'b1;
              be_n      <= ~req_be;
              mion      <= req_mio;
              dcn       <= req_dc;
              wrn       <= req_we;        // W/R#: 1=write 0=read
              cachen    <= req_cache ? 1'b0 : 1'b1;
              // [FIX-7] SCYC only for a misaligned/>2-cycle locked group; a
              // normal aligned 2-cycle locked pair leaves SCYC negated.
              scycn     <= (req_lock && req_split) ? 1'b0 : 1'b1;
              // LOCK# asserted on first clock of first locked cycle, held
              if (req_lock) begin
                lockn       <= 1'b0;
                lock_active <= 1'b1;
              end else begin
                lockn       <= lock_active ? 1'b0 : 1'b1; // keep if mid-group
              end
              // latch cycle attributes
              cyc_we       <= req_we;
              cyc_cache    <= req_cache;
              cyc_addr     <= req_addr;
              cyc_be       <= req_be;
              cyc_wdata    <= req_wdata;
              cyc_wb       <= req_wb;
              burst_q_done <= 1'b0;
              is_burst     <= 1'b0;
              burst_base   <= req_addr[1:0];
              burst_idx    <= 2'd0;
              beats_left   <= SINGLE_BEATS; // provisional; upgraded if burst qualifies
              // [FIX-11] write data driven from T2 onward, not in T1.
              d_out        <= req_wdata;
              d_oe         <= 1'b0;         // assert on the T1->T2 edge below
              outstanding  <= 2'd1;
              req_ack      <= 1'b1;         // request accepted
            end
            else begin
              // truly idle
              adsn <= 1'b1;
              a_oe <= 1'b0;
              d_oe <= 1'b0;
              lockn <= lock_active ? 1'b0 : 1'b1;
            end
          end

          // ------------------------------------------------------------------
          S_T1: begin
            // ADS# was a one-clock pulse: negate it now, move to data phase.
            adsn <= 1'b1;
            st   <= S_T2;
            // [FIX-11] drive write data from T2 onward.
            d_oe <= cyc_we;
          end

          // ------------------------------------------------------------------
          S_T2: begin
            // Qualify cacheability/burst at first BRDY# or NA#.
            if (!burst_q_done && (!brdyn || !nan)) begin
              burst_q_done <= 1'b1;
              if (cyc_cache && !kenn && !cyc_we) begin
                is_burst   <= 1'b1;
                beats_left <= BURST_BEATS;
              end
            end

            // Is THIS clock's BRDY# the terminating beat of the current cycle?
            // [FIX-1] compute it up-front so the pipeline-accept and the
            // last-beat completion are mutually exclusive (no racing `st`).
            // [FIX-5] for a burst we also drop a_oe once we are past T1 (address
            // driven once, not re-driven each beat).
            begin : t2_body
              logic last_beat;
              last_beat = (!brdyn) && (effective_beats() <= 3'd1);

              // [FIX-5] do not drive the address bus during burst data beats.
              if ((is_burst || (!burst_q_done && cyc_cache && !kenn && !cyc_we))
                  && !ahold)
                a_oe <= 1'b0;

              // Pipeline: only if NA# asserted, a 2nd request is available, the
              // current cycle is NOT terminating this clock [FIX-1], the current
              // cycle is single-beat (not a burst) [FIX-4], AHOLD is not floating
              // the address bus [FIX-8], and the system is not backing off.
              if (!nan && !p_valid && req && !last_beat
                  && !cyc_blocks_pipe() && !ahold) begin
                p_valid <= 1'b1;
                p_we    <= req_we;
                p_cache <= req_cache;
                p_mio   <= req_mio;
                p_dc    <= req_dc;
                p_lock  <= req_lock;
                p_split <= req_split;
                p_wb    <= req_wb;
                p_addr  <= req_addr;
                p_be    <= req_be;
                p_wdata <= req_wdata;
                req_ack <= 1'b1;
                st      <= S_T12;
              end

              // BRDY#: a beat completed.
              if (!brdyn) begin
                rsp_valid <= 1'b1;
                rsp_data  <= d_in;
                if (last_beat) begin
                  // last beat of this cycle
                  rsp_last    <= 1'b1;
                  outstanding <= outstanding - 2'd1;
                  d_oe        <= 1'b0;
                  is_burst    <= 1'b0;
                  // close out / handle locked group / snoop writeback
                  if (lock_active && !lock_group_done()) begin
                    // mid locked group: keep LOCK# asserted, wait for write req
                    lockn <= 1'b0;
                  end else begin
                    lock_active <= 1'b0;
                    lockn       <= 1'b1;
                  end
                  // [FIX-6] release HITM# only when the ACTUAL writeback of the
                  // snooped line completes (cyc_wb), not on any unrelated write.
                  if (wb_req && cyc_we && cyc_wb) begin
                    wb_req <= 1'b0;
                    hitmn  <= 1'b1;
                  end
                  // [FIX-3] If a second cycle is queued in p_* WITHOUT having been
                  // pipelined through T12/T2P (the BOFF# two-cycle restart re-queues
                  // it here), do NOT drop it: go to IDLE keeping p_valid set, and
                  // S_IDLE will launch it as a fresh ADS# next clock (P3-legal:
                  // ADS# falls only from IDLE/T12/BOFF). The normal NA# pipeline
                  // never reaches this branch with p_valid set (it lives in T2P),
                  // so the IDLE-relaunch only fires for the BOFF# 2nd-cycle replay.
                  st <= S_IDLE;
                end else begin
                  // more burst beats to come; advance to the next Table 6-12
                  // transfer (model only; pins are held / floated).
                  beats_left <= effective_beats() - 3'd1;
                  burst_idx  <= burst_idx + 2'd1;
                  cyc_addr   <= {cyc_addr[28:2],
                                 burst_addr(burst_base, burst_idx + 2'd1)};
                end
              end
            end
          end

          // ------------------------------------------------------------------
          S_T12: begin
            // drive ADS# for the pipelined (2nd) cycle, one clock.
            // [FIX-8] AHOLD must not have floated the address bus here; the
            // pipeline-accept guard in S_T2 already required !ahold, but guard
            // again in case AHOLD asserted in between: if AHOLD is active we do
            // NOT issue the ADS#, we hold in T12 until the address bus is ours.
            if (!ahold) begin
              adsn        <= 1'b0;
              a           <= p_addr;
              a_oe        <= 1'b1;
              be_n        <= ~p_be;
              mion        <= p_mio;
              dcn         <= p_dc;
              wrn         <= p_we;
              cachen      <= p_cache ? 1'b0 : 1'b1;
              scycn       <= (p_lock && p_split) ? 1'b0 : 1'b1;
              outstanding <= 2'd2;
              st          <= S_T2P;
            end
            // else: stall in T12 until AHOLD clears (a_oe already forced 0 below)
          end

          // ------------------------------------------------------------------
          S_T2P: begin
            adsn <= 1'b1;  // 2nd ADS# was one clock
            // BRDY# here completes the FIRST (older) cycle.
            // [FIX-4] the older cycle is guaranteed single-beat: the S_T2
            // pipeline-accept guard (cyc_blocks_pipe) forbids pipelining behind
            // a burst, so completing on the first BRDY# is always correct here.
            if (!brdyn) begin
              rsp_valid   <= 1'b1;
              rsp_data    <= d_in;
              rsp_last    <= 1'b1;        // older cycle is single-beat by construction
              outstanding <= outstanding - 2'd1;
              // older cycle was the locked read of an RMW? release per group rule
              if (lock_active && cyc_we) begin
                lock_active <= 1'b0;
                lockn       <= 1'b1;
              end
              // [FIX-6] older write that was the actual writeback -> release HITM#
              if (wb_req && cyc_we && cyc_wb) begin
                wb_req <= 1'b0;
                hitmn  <= 1'b1;
              end
              // promote pipelined cycle to current
              cyc_we    <= p_we;
              cyc_cache <= p_cache;
              cyc_addr  <= p_addr;
              cyc_be    <= p_be;
              cyc_wdata <= p_wdata;
              cyc_wb    <= p_wb;
              d_out     <= p_wdata;
              d_oe      <= p_we;
              if (p_lock) begin
                lock_active <= 1'b1;
                lockn       <= 1'b0;
              end
              burst_base   <= p_addr[1:0];
              burst_idx    <= 2'd0;
              beats_left   <= SINGLE_BEATS;
              is_burst     <= 1'b0;
              burst_q_done <= 1'b0;
              p_valid   <= 1'b0;
              st        <= S_T2;
            end
          end

          // ------------------------------------------------------------------
          S_BOFF: begin
            adsn <= 1'b1;
            a_oe <= 1'b0;
            d_oe <= 1'b0;
            if (boffn) begin
              // BOFF# negated: restart aborted cycle(s) from a fresh ADS#.
              // [FIX-3] replay the OLDER cycle first; if a second (pipelined)
              // cycle was also outstanding, re-queue it into p_* so the normal
              // pipeline path re-issues it (in its entirety) after the first.
              if (boff_pending) begin
                st        <= S_T1;
                adsn      <= 1'b0;
                a         <= bsv_addr;
                a_oe      <= 1'b1;
                be_n      <= ~bsv_be;
                mion      <= bsv_mio;
                dcn       <= bsv_dc;
                wrn       <= bsv_we;
                cachen    <= bsv_cache ? 1'b0 : 1'b1;
                scycn     <= (bsv_lock && bsv_split) ? 1'b0 : 1'b1;
                lockn     <= bsv_lock ? 1'b0 : 1'b1;
                lock_active <= bsv_lock;
                cyc_we    <= bsv_we;
                cyc_cache <= bsv_cache;
                cyc_addr  <= bsv_addr;
                cyc_be    <= bsv_be;
                cyc_wdata <= bsv_wdata;
                cyc_wb    <= bsv_wb;
                d_out     <= bsv_wdata;
                d_oe      <= 1'b0;          // [FIX-11] drive data from T2
                // restore burst progress of the older cycle in its entirety
                burst_q_done <= bsv_is_burst;
                is_burst     <= bsv_is_burst;
                beats_left   <= bsv_is_burst ? bsv_beats : SINGLE_BEATS;
                burst_base   <= bsv_base;
                burst_idx    <= bsv_idx;
                // [FIX-3] re-queue the second cycle for the pipeline path
                if (bsv2_valid) begin
                  p_valid <= 1'b1;
                  p_we    <= bsv2_we;
                  p_cache <= bsv2_cache;
                  p_mio   <= bsv2_mio;
                  p_dc    <= bsv2_dc;
                  p_lock  <= bsv2_lock;
                  p_split <= bsv2_split;
                  p_wb    <= bsv2_wb;
                  p_addr  <= bsv2_addr;
                  p_be    <= bsv2_be;
                  p_wdata <= bsv2_wdata;
                end else begin
                  p_valid <= 1'b0;
                end
                outstanding  <= bsv2_valid ? 2'd2 : 2'd1;
                boff_pending <= 1'b0;
                bsv2_valid   <= 1'b0;
                req_ack      <= 1'b1;
              end else begin
                st <= S_IDLE;
              end
            end
          end

          // ------------------------------------------------------------------
          S_HOLD: begin
            adsn <= 1'b1;
            a_oe <= 1'b0;
            d_oe <= 1'b0;
            if (!hold) begin
              hlda <= 1'b0;
              st   <= S_IDLE;
            end
          end

          default: st <= S_IDLE;
        endcase
      end

      // ----------------------------------------------------------------------
      // Snoop / inquire tracker (runs in parallel; AHOLD floats addr bus only)
      // ----------------------------------------------------------------------
      if (ahold) a_oe <= 1'b0;   // AHOLD: stop driving address bus

      case (sn_st)
        SN_IDLE: begin
          // [FIX-2 scope note] The system drives the inquire address when it
          // owns the address bus. We sample EADS# under AHOLD (and also when the
          // system owns the bus via HLDA or BOFF#), per datasheet EADS# (Table
          // 2 p.16) which is not gated solely by AHOLD.
          if ((ahold || hlda || !boffn) && !eadsn) begin
            sn_st     <= SN_S1;
            // self-consistency snoop model: "hit" when a_in is non-zero,
            // "modified" when a_in[0]==1. Deterministic & testable.
            // [FIX-2] snoop_mod is INV-INDEPENDENT: an inquire hit to a Modified
            // line ALWAYS asserts HITM# and requests writeback. INV only selects
            // the final cache-line state after the writeback (1=>I, 0=>S).
            snoop_hit <= |a_in;
            snoop_mod <= a_in[0];
            snoop_inv <= inv;
          end
        end
        SN_S1: sn_st <= SN_S2;
        SN_S2: begin
          // drive HIT#/HITM# exactly 2 clocks after EADS#
          if (snoop_hit) begin
            hitn  <= 1'b0;
            if (snoop_mod) begin
              hitmn  <= 1'b0;
              wb_req <= 1'b1;   // request a writeback of the modified line
            end
          end else begin
            hitn  <= 1'b1;      // miss
            hitmn <= 1'b1;
          end
          sn_st <= SN_IDLE;
        end
        default: sn_st <= SN_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
