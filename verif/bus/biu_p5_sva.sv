// ============================================================================
// biu_p5_sva.sv -- bind-able SVA protocol-invariant checker for biu_p5.
//
// M5B-int: the 19 mutation-validated concurrent SVA from the STANDALONE
// self-consistency testbench (verif/bus/tb_biu_p5.sv P1..P15) extracted into a
// checker module that can be `bind`-ed into biu_p5 so the SAME invariants are
// checked IN-SYSTEM during real core traffic (bus_mode=1) -- not just in the
// standalone directed scenarios. The properties are VERBATIM copies of the
// standalone TB's; only the surrounding module/ports differ (here they are
// driven by hierarchical binding to the live biu_p5 nets, there by the TB).
//
// Usage (integrated bus_mode=1 SVA run): built by `make -C verif/tb rtl-sva`,
// which adds the Verilator SVA flag and this file (plus its bind, below).
// The standalone gate (verif/bus/run.sh) does NOT use this file -- it keeps its
// own in-line SVA -- so this is purely additive and the standalone 19 SVA / 76
// checks are unchanged.
//
// All ports map 1:1 (by name) to biu_p5 module-level nets, so the bind uses .*.
// ============================================================================
`default_nettype none
module biu_p5_sva (
    input  wire        clk,
    input  wire        reset,
    input  wire        adsn,
    input  wire        a_oe,
    input  wire        wrn,
    input  wire        d_oe,
    input  wire        lockn,
    input  wire        hlda,
    input  wire        hitn,
    input  wire        hitmn,
    input  wire        rsp_valid,
    input  wire        rsp_last,
    input  wire        wb_req,
    input  wire        brdyn,
    input  wire        nan,
    input  wire        hold,
    input  wire        ahold,
    input  wire        boffn,
    input  wire        eadsn,
    input  wire [2:0]  dbg_state,
    input  wire        dbg_is_burst,
    input  wire [1:0]  dbg_outstanding,
    input  wire [1:0]  dbg_snoop_state
);
  // FSM state name mirrors (same encoding as biu_p5 localparams)
  localparam [2:0] S_IDLE=0, S_T1=1, S_T2=2, S_T12=3, S_T2P=4, S_BOFF=5, S_HOLD=6;
  localparam [1:0] SN_IDLE=0, SN_S1=1, SN_S2=2;

  // P1: ADS# is a one-clock pulse.
  property p1_ads_one_clock;
    @(posedge clk) disable iff (reset) $fell(adsn) |=> $rose(adsn);
  endproperty
  a_p1: assert property (p1_ads_one_clock)
    else $error("[in-system] P1 violated: ADS# held >1 clock");

  // P2: BRDY# beat count per cycle (1 single / 4 burst).
  integer beats_in_cycle;
  reg     cycle_was_burst;
  always @(posedge clk) begin
    if (reset) begin
      beats_in_cycle  <= 0;
      cycle_was_burst <= 1'b0;
    end else begin
      if (dbg_is_burst) cycle_was_burst <= 1'b1;
      if (rsp_valid && rsp_last) begin
        beats_in_cycle  <= 0;
        cycle_was_burst <= 1'b0;
      end else if (rsp_valid && !rsp_last) begin
        beats_in_cycle  <= beats_in_cycle + 1;
      end
    end
  end
  property p2_beat_count;
    @(posedge clk) disable iff (reset)
      (rsp_valid && rsp_last) |->
        ( (cycle_was_burst && beats_in_cycle==3)
          || (!cycle_was_burst && beats_in_cycle==0) );
  endproperty
  a_p2: assert property (p2_beat_count)
    else $error("[in-system] P2 violated: wrong BRDY# beat count at rsp_last");

  // P3: ADS# only from IDLE / T12 / BOFF.
  property p3_ads_legal_origin;
    @(posedge clk) disable iff (reset)
      $fell(adsn) |-> ($past(dbg_state)==S_IDLE ||
                       $past(dbg_state)==S_T12  ||
                       $past(dbg_state)==S_BOFF);
  endproperty
  a_p3: assert property (p3_ads_legal_origin)
    else $error("[in-system] P3 violated: ADS# from illegal state");

  // P3b: pipelined ADS# (from T12) implies NA# was on the bus in T2.
  reg na_pin_seen;
  always @(posedge clk) begin
    if (reset)                          na_pin_seen <= 1'b0;
    else if (dbg_state==S_T2 && !nan)   na_pin_seen <= 1'b1;
    else if (dbg_state==S_IDLE)         na_pin_seen <= 1'b0;
    else if (dbg_state==S_T2P)          na_pin_seen <= 1'b0;
  end
  property p3b_pipe_requires_na;
    @(posedge clk) disable iff (reset)
      ($fell(adsn) && $past(dbg_state)==S_T12) |-> na_pin_seen;
  endproperty
  a_p3b: assert property (p3b_pipe_requires_na)
    else $error("[in-system] P3b violated: pipelined ADS# without NA# on the bus");

  // P4: <=2 outstanding.
  property p4_outstanding_le2;
    @(posedge clk) disable iff (reset) (dbg_outstanding <= 2);
  endproperty
  a_p4: assert property (p4_outstanding_le2)
    else $error("[in-system] P4 violated: >2 outstanding cycles");

  // P5: LOCK# continuity.
  reg lockn_q;
  always @(posedge clk) lockn_q <= lockn;
  property p5_lock_continuity;
    @(posedge clk) disable iff (reset)
      ($rose(lockn)) |->
        ( ($past(dbg_state)==S_T2 || $past(dbg_state)==S_T2P)
          && $past(wrn)==1'b1 && $past(brdyn)==1'b0 );
  endproperty
  a_p5: assert property (p5_lock_continuity)
    else $error("[in-system] P5 violated: LOCK# glitched high mid locked group");

  // P6: no HLDA during LOCK#.
  property p6_no_hold_in_lock;
    @(posedge clk) disable iff (reset) !(hlda && !lockn);
  endproperty
  a_p6: assert property (p6_no_hold_in_lock)
    else $error("[in-system] P6 violated: HLDA during LOCK#");

  // P7: AHOLD floats the address bus.
  property p7_ahold_floats_addr;
    @(posedge clk) disable iff (reset) ($past(ahold) |-> !a_oe);
  endproperty
  a_p7: assert property (p7_ahold_floats_addr)
    else $error("[in-system] P7 violated: address driven during AHOLD");

  // P7b: no fresh ADS# while AHOLD floats the address bus.
  property p7b_no_ads_floated;
    @(posedge clk) disable iff (reset) (!adsn) |-> a_oe;
  endproperty
  a_p7b: assert property (p7b_no_ads_floated)
    else $error("[in-system] P7b violated: ADS# asserted with address bus floated");

  // P8: snoop launches only on a qualified EADS#.
  property p8_snoop_launch_qualified;
    @(posedge clk) disable iff (reset)
      ($past(dbg_snoop_state)==SN_IDLE && dbg_snoop_state==SN_S1)
        |-> $past((ahold || hlda || !boffn) && !eadsn);
  endproperty
  a_p8: assert property (p8_snoop_launch_qualified)
    else $error("[in-system] P8 violated: snoop launched without a qualified EADS#");

  // P9: HIT#/HITM# driven exactly 2 clocks after EADS#.
  property p9_hit_timing;
    @(posedge clk) disable iff (reset)
      ($changed(hitn)) |-> ($past(dbg_snoop_state)==SN_S2);
  endproperty
  a_p9: assert property (p9_hit_timing)
    else $error("[in-system] P9 violated: HIT# changed outside the 2-clk window");

  // P10: HITM# implies a pending writeback.
  property p10_hitm_implies_wb;
    @(posedge clk) disable iff (reset) (!hitmn) |-> wb_req;
  endproperty
  a_p10: assert property (p10_hitm_implies_wb)
    else $error("[in-system] P10 violated: HITM# without a pending writeback");

  // P10b: HITM# released only by the writeback completing.
  property p10b_hitm_release;
    @(posedge clk) disable iff (reset)
      ($rose(hitmn)) |->
        ( ($past(dbg_state)==S_T2 || $past(dbg_state)==S_T2P)
          && $past(wrn)==1'b1 && $past(brdyn)==1'b0 );
  endproperty
  a_p10b: assert property (p10b_hitm_release)
    else $error("[in-system] P10b violated: HITM# released other than by the writeback");

  // P11: BOFF# floats the bus next clock.
  property p11_boff_floats;
    @(posedge clk) disable iff (reset)
      ($fell(boffn) && $past(dbg_state)!=S_HOLD) |=> (!a_oe && !d_oe && adsn);
  endproperty
  a_p11: assert property (p11_boff_floats)
    else $error("[in-system] P11 violated: BOFF# did not float bus");

  // P12: BOFF# restart issues a fresh ADS#.
  property p12_boff_restart;
    @(posedge clk) disable iff (reset)
      ($past(dbg_state)==S_BOFF && dbg_state==S_T1) |-> (!adsn);
  endproperty
  a_p12: assert property (p12_boff_restart)
    else $error("[in-system] P12 violated: BOFF# restart did not assert ADS#");

  // P13: after reset, idle + inactive (HLDA may assert if HOLD held).
  property p13_reset_idle;
    @(posedge clk) (reset && !hold) |=> (dbg_state==S_IDLE && adsn && lockn && !hlda
                              && !a_oe && !d_oe && hitn && hitmn);
  endproperty
  a_p13: assert property (p13_reset_idle)
    else $error("[in-system] P13 violated: not idle/inactive after reset");

  // P14: d_oe only on writes.
  property p14_doe_write_only;
    @(posedge clk) disable iff (reset) d_oe |-> (wrn==1'b1);
  endproperty
  a_p14: assert property (p14_doe_write_only)
    else $error("[in-system] P14 violated: d_oe on a non-write");

  // P14b: write data not driven in T1.
  property p14b_no_data_in_t1;
    @(posedge clk) disable iff (reset) (dbg_state==S_T1) |-> !d_oe;
  endproperty
  a_p14b: assert property (p14b_no_data_in_t1)
    else $error("[in-system] P14b violated: write data driven during T1");

  // P15: no spurious rsp_valid in IDLE with 0 outstanding.
  property p15_no_spurious_rsp;
    @(posedge clk) disable iff (reset)
      ($past(dbg_state)==S_IDLE && $past(dbg_outstanding)==0 && $past(!brdyn))
        |-> !rsp_valid;
  endproperty
  a_p15: assert property (p15_no_spurious_rsp)
    else $error("[in-system] P15 violated: spurious rsp_valid in IDLE");

endmodule
`default_nettype wire

// Bind the checker into every biu_p5 instance. The port names match biu_p5's
// module-level nets exactly, so .* resolves them by hierarchical reference.
bind biu_p5 biu_p5_sva u_biu_p5_sva (.*);
