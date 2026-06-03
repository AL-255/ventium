// ============================================================================
// tb_biu_p5.sv -- standalone self-consistency testbench + SVA protocol
// invariants for the Ventium M5B Bus Interface Unit (biu_p5).
//
// No differential oracle exists for the pin-level bus (M2S/no-oracle pattern):
// this drives one directed scenario per bus-cycle type and embeds concurrent
// SVA assertions for the datasheet protocol rules (241997-010 Table 2 / sec 3),
// plus directed corner scenarios that REPRODUCE each Phase-2 review finding so
// the Phase-3 fixes are exercised (not merely latent-masked).
//
// Run with Verilator (--binary --assert --timing); see run.sh / Makefile.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_biu_p5;

  // -------------------------------------------------------------------------
  // clock / reset
  // -------------------------------------------------------------------------
  reg clk = 1'b0;
  always #5 clk = ~clk;   // 100 MHz model clock
  reg reset;

  // DUT FSM state names (mirror of biu_p5 localparams, for assertions/display)
  localparam [2:0] S_IDLE=0, S_T1=1, S_T2=2, S_T12=3, S_T2P=4, S_BOFF=5, S_HOLD=6;

  // -------------------------------------------------------------------------
  // core-side request interface
  // -------------------------------------------------------------------------
  reg         req, req_we, req_cache, req_lock, req_split, req_mio, req_dc, req_wb;
  reg  [28:0] req_addr;
  reg  [7:0]  req_be;
  reg  [63:0] req_wdata;
  wire        req_ack, rsp_valid, rsp_last, wb_req;
  wire [63:0] rsp_data;

  // -------------------------------------------------------------------------
  // bus pins
  // -------------------------------------------------------------------------
  wire        adsn, a_oe, mion, dcn, wrn, cachen, scycn, lockn, d_oe, hlda, breq;
  wire        hitn, hitmn;
  wire [28:0] a;
  wire [7:0]  be_n;
  wire [63:0] d_out;
  wire [2:0]  dbg_state;
  wire        dbg_is_burst;
  wire [1:0]  dbg_outstanding;
  wire        dbg_pipe_burst, dbg_inv_state;
  wire [1:0]  dbg_snoop_state;
  localparam [1:0] SN_IDLE=0, SN_S1=1, SN_S2=2;

  // system-driven inputs
  reg  [63:0] d_in;
  reg         brdyn, nan, kenn, hold, boffn, ahold, eadsn, inv;
  reg  [26:0] a_in;

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  biu_p5 dut (
    .clk(clk), .reset(reset),
    .req(req), .req_we(req_we), .req_cache(req_cache), .req_lock(req_lock),
    .req_split(req_split), .req_mio(req_mio), .req_dc(req_dc),
    .req_addr(req_addr), .req_be(req_be), .req_wdata(req_wdata), .req_wb(req_wb),
    .req_ack(req_ack), .rsp_valid(rsp_valid), .rsp_data(rsp_data),
    .rsp_last(rsp_last), .wb_req(wb_req),
    .adsn(adsn), .a(a), .a_oe(a_oe), .be_n(be_n), .mion(mion), .dcn(dcn),
    .wrn(wrn), .cachen(cachen), .scycn(scycn), .lockn(lockn),
    .d_out(d_out), .d_oe(d_oe), .d_in(d_in), .brdyn(brdyn), .nan(nan),
    .kenn(kenn), .hold(hold), .hlda(hlda), .boffn(boffn), .breq(breq),
    .ahold(ahold), .eadsn(eadsn), .inv(inv), .a_in(a_in),
    .hitn(hitn), .hitmn(hitmn),
    .dbg_state(dbg_state), .dbg_is_burst(dbg_is_burst),
    .dbg_outstanding(dbg_outstanding),
    .dbg_pipe_burst(dbg_pipe_burst), .dbg_inv_state(dbg_inv_state),
    .dbg_snoop_state(dbg_snoop_state)
  );

  // -------------------------------------------------------------------------
  // scoreboard / counters
  // -------------------------------------------------------------------------
  integer beats_seen;
  integer errors;
  integer checks_pass;
  integer ads_pulses;

  task automatic chk(input cond, input [511:0] name);
    begin
      if (cond) begin checks_pass = checks_pass + 1; $display("  PASS: %0s", name); end
      else      begin errors = errors + 1;          $display("  FAIL: %0s", name); end
    end
  endtask

  // idle the system response lines
  task automatic idle_inputs;
    begin
      req=0; req_we=0; req_cache=0; req_lock=0; req_split=0; req_mio=1; req_dc=1; req_wb=0;
      req_addr=0; req_be=8'hFF; req_wdata=0;
      d_in=0; brdyn=1; nan=1; kenn=1; hold=0; boffn=1; ahold=0; eadsn=1; inv=0; a_in=0;
    end
  endtask

  task automatic tick(input integer n);
    integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end
  endtask

  // -------------------------------------------------------------------------
  // SVA protocol invariants (concurrent assertions)
  // -------------------------------------------------------------------------
  // P1: ADS# is a one-clock pulse (asserted low for exactly one cycle).
  property p1_ads_one_clock;
    @(posedge clk) disable iff (reset)
      $fell(adsn) |=> $rose(adsn);
  endproperty
  a_p1: assert property (p1_ads_one_clock)
    else $error("P1 violated: ADS# held >1 clock");

  // ---- P2: BRDY# beat count per cycle ----
  // A single (non-burst) cycle terminates on exactly 1 BRDY#; a burst line fill
  // on exactly 4. We count rsp_valid beats accepted *within the current cycle*
  // and latch whether the cycle was a burst (dbg_is_burst is cleared by the DUT
  // on the same edge it raises rsp_last, so we cannot read it at rsp_last; the
  // latch holds it stable across the whole cycle). At the rsp_last beat the total
  // accepted beats (beats_in_cycle, NOT yet counting this beat) must be 3 for a
  // burst (this is the 4th) or 0 for a single (this is the 1st).  Non-vacuous:
  // it would fire if T2P truncated a burst to one beat [FIX-4] or if a burst
  // returned the wrong number of beats.
  integer beats_in_cycle;
  reg     cycle_was_burst;
  always @(posedge clk) begin
    if (reset) begin
      beats_in_cycle  <= 0;
      cycle_was_burst <= 1'b0;
    end else begin
      if (dbg_is_burst) cycle_was_burst <= 1'b1;   // latch burst-ness for the cycle
      if (rsp_valid && rsp_last) begin
        beats_in_cycle  <= 0;                      // cycle ended; reset for next
        cycle_was_burst <= 1'b0;
      end else if (rsp_valid && !rsp_last) begin
        beats_in_cycle  <= beats_in_cycle + 1;
      end
    end
  end
  property p2_beat_count;
    @(posedge clk) disable iff (reset)
      (rsp_valid && rsp_last) |->
        ( (cycle_was_burst && beats_in_cycle==3)        // 3 prior + this = 4
          || (!cycle_was_burst && beats_in_cycle==0) ); // 0 prior + this = 1
  endproperty
  a_p2: assert property (p2_beat_count)
    else $error("P2 violated: wrong BRDY# beat count at rsp_last");

  // P3: no new ADS# while a non-pipelined cycle is outstanding unless NA# was
  // asserted. A falling ADS# is legal from IDLE, from BOFF (restart), or as a
  // PIPELINED launch (only entered from T12, reached only after sampling NA#).
  property p3_ads_legal_origin;
    @(posedge clk) disable iff (reset)
      $fell(adsn) |-> ($past(dbg_state)==S_IDLE  ||   // brand-new cycle
                       $past(dbg_state)==S_T12   ||   // pipelined launch (NA# seen)
                       $past(dbg_state)==S_BOFF);     // backoff restart
  endproperty
  a_p3: assert property (p3_ads_legal_origin)
    else $error("P3 violated: ADS# from illegal state");

  // P3b: the pipelined launch (ADS# from T12) is only reachable after NA# was
  // sampled. NOTE [FIX]: the previous version was vacuous because na_was_seen
  // was set by the SAME condition the DUT uses to enter T12. Here na_was_seen is
  // tracked from the ACTUAL NA# input pin sampled in T2 -- an independent
  // observation of the protocol stimulus, not a mirror of the DUT branch. If the
  // DUT entered T12 (and thus pulls ADS#) it must be because NA# was genuinely
  // asserted on the bus while in T2.
  reg na_pin_seen;
  always @(posedge clk) begin
    if (reset)                          na_pin_seen <= 1'b0;
    else if (dbg_state==S_T2 && !nan)   na_pin_seen <= 1'b1;   // raw NA# pin
    else if (dbg_state==S_IDLE)         na_pin_seen <= 1'b0;
    else if (dbg_state==S_T2P)          na_pin_seen <= 1'b0;   // consumed
  end
  property p3b_pipe_requires_na;
    @(posedge clk) disable iff (reset)
      ($fell(adsn) && $past(dbg_state)==S_T12) |-> na_pin_seen;
  endproperty
  a_p3b: assert property (p3b_pipe_requires_na)
    else $error("P3b violated: pipelined ADS# without NA# on the bus");

  // P4: outstanding-cycle count never exceeds 2.
  property p4_outstanding_le2;
    @(posedge clk) disable iff (reset) (dbg_outstanding <= 2);
  endproperty
  a_p4: assert property (p4_outstanding_le2)
    else $error("P4 violated: >2 outstanding cycles");

  // ---- P5: LOCK# continuity across a locked group ----
  // Once LOCK# asserts it must NOT glitch high until the group's last BRDY#.
  // The locked-group end is the terminating BRDY# of a locked WRITE cycle
  // (lock_group_done == cyc_we). So while LOCK# is low, it may only rise on a
  // clock where a locked write completes. Equivalent SVA: LOCK# may rise only
  // when the previous clock was a data-state with a write completing.
  reg lockn_q;
  always @(posedge clk) lockn_q <= lockn;
  property p5_lock_continuity;
    @(posedge clk) disable iff (reset)
      // LOCK# rose this clock (was 0, now 1) ==> last clock a locked write
      // terminated: state T2/T2P AND wrn==write AND BRDY# was active.
      ($rose(lockn)) |->
        ( ($past(dbg_state)==S_T2 || $past(dbg_state)==S_T2P)
          && $past(wrn)==1'b1 && $past(brdyn)==1'b0 );
  endproperty
  a_p5: assert property (p5_lock_continuity)
    else $error("P5 violated: LOCK# glitched high mid locked group");

  // P6: HLDA is never asserted while LOCK# is asserted.
  property p6_no_hold_in_lock;
    @(posedge clk) disable iff (reset) !(hlda && !lockn);
  endproperty
  a_p6: assert property (p6_no_hold_in_lock)
    else $error("P6 violated: HLDA during LOCK#");

  // P7: while AHOLD is active, BIU must not drive the address bus.
  property p7_ahold_floats_addr;
    @(posedge clk) disable iff (reset) ($past(ahold) |-> !a_oe);
  endproperty
  a_p7: assert property (p7_ahold_floats_addr)
    else $error("P7 violated: address driven during AHOLD");

  // ---- P7b (NEW): no fresh ADS# while AHOLD floats the address bus ----
  // [FIX-8] An ADS# must never be asserted with a_oe forced low. Whenever ADS#
  // is asserted (adsn==0) the BIU must be driving a valid address (a_oe==1).
  property p7b_no_ads_floated;
    @(posedge clk) disable iff (reset) (!adsn) |-> a_oe;
  endproperty
  a_p7b: assert property (p7b_no_ads_floated)
    else $error("P7b violated: ADS# asserted with address bus floated");

  // ---- P8 (NEW): a snoop is launched only on a qualified EADS# ----
  // The snoop tracker leaves SN_IDLE (-> SN_S1) only when EADS# is sampled while
  // the system owns the address bus (AHOLD, HLDA, or BOFF#). Asserted directly
  // against the snoop FSM: any SN_IDLE->SN_S1 transition implies the qualifier +
  // EADS# were active on the prior clock. Non-vacuous: a snoop launched without a
  // qualified EADS# (e.g. during a normal cycle) would fire it.
  property p8_snoop_launch_qualified;
    @(posedge clk) disable iff (reset)
      ($past(dbg_snoop_state)==SN_IDLE && dbg_snoop_state==SN_S1)
        |-> $past((ahold || hlda || !boffn) && !eadsn);
  endproperty
  a_p8: assert property (p8_snoop_launch_qualified)
    else $error("P8 violated: snoop launched without a qualified EADS#");

  // ---- P9 (NEW): HIT#/HITM# driven exactly 2 clocks after EADS# sampled ----
  // HIT# is updated only in SN_S2, which is reached exactly 2 clocks after the
  // EADS# sample (SN_IDLE -> SN_S1 -> SN_S2). So any change of HIT# implies the
  // snoop FSM was in SN_S2 the prior clock.
  property p9_hit_timing;
    @(posedge clk) disable iff (reset)
      ($changed(hitn)) |-> ($past(dbg_snoop_state)==SN_S2);
  endproperty
  a_p9: assert property (p9_hit_timing)
    else $error("P9 violated: HIT# changed outside the 2-clk-after-EADS# window");

  // ---- P9: HIT#/HITM# timing -- checked directly in the snoop scenario. ----

  // ---- P10 (NEW): HITM# implies a writeback is requested ----
  // [FIX-2/FIX-6] Whenever HITM# is asserted (hitmn==0), wb_req must be set,
  // i.e. a writeback is outstanding. HITM# never floats without a pending WB.
  property p10_hitm_implies_wb;
    @(posedge clk) disable iff (reset) (!hitmn) |-> wb_req;
  endproperty
  a_p10: assert property (p10_hitm_implies_wb)
    else $error("P10 violated: HITM# asserted without a pending writeback");

  // ---- P10b (NEW): HITM# released only by the writeback completing ----
  // [FIX-6] HITM# may rise (deassert) only on a clock where a writeback write
  // cycle terminated: state T2/T2P, wrn==write, BRDY# active.
  property p10b_hitm_release;
    @(posedge clk) disable iff (reset)
      ($rose(hitmn)) |->
        ( ($past(dbg_state)==S_T2 || $past(dbg_state)==S_T2P)
          && $past(wrn)==1'b1 && $past(brdyn)==1'b0 );
  endproperty
  a_p10b: assert property (p10b_hitm_release)
    else $error("P10b violated: HITM# released other than by the writeback");

  // P11: one clock after BOFF# is sampled, address+data buses are floated and
  //      ADS# is negated.
  property p11_boff_floats;
    @(posedge clk) disable iff (reset)
      ($fell(boffn) && $past(dbg_state)!=S_HOLD) |=> (!a_oe && !d_oe && adsn);
  endproperty
  a_p11: assert property (p11_boff_floats)
    else $error("P11 violated: BOFF# did not float bus");

  // ---- P12 (NEW): BOFF# restart issues a fresh ADS# ----
  // [FIX-3] After BOFF# negates while a cycle was pending, an ADS# (adsn==0)
  // must follow within a couple of clocks (the restart). We assert that leaving
  // S_BOFF with a pending cycle goes to T1 (which pulses ADS#), never silently
  // to IDLE dropping the cycle.
  property p12_boff_restart;
    @(posedge clk) disable iff (reset)
      ($past(dbg_state)==S_BOFF && dbg_state==S_T1) |-> (!adsn);
  endproperty
  a_p12: assert property (p12_boff_restart)
    else $error("P12 violated: BOFF# restart did not assert ADS#");

  // P13: after reset, FSM is idle and bus inactive (HLDA may assert if HOLD held).
  property p13_reset_idle;
    @(posedge clk) (reset && !hold) |=> (dbg_state==S_IDLE && adsn && lockn && !hlda
                              && !a_oe && !d_oe && hitn && hitmn);
  endproperty
  a_p13: assert property (p13_reset_idle)
    else $error("P13 violated: not idle/inactive after reset");

  // P14: data output enable only asserted during a write data phase.
  property p14_doe_write_only;
    @(posedge clk) disable iff (reset)
      d_oe |-> (wrn==1'b1);   // wrn==1 => write cycle
  endproperty
  a_p14: assert property (p14_doe_write_only)
    else $error("P14 violated: d_oe on a non-write");

  // P14b (NEW): write data is not driven during T1 (drives from T2 onward).
  // [FIX-11] In S_T1, d_oe must be low (data driven from the T1->T2 edge).
  property p14b_no_data_in_t1;
    @(posedge clk) disable iff (reset)
      (dbg_state==S_T1) |-> !d_oe;
  endproperty
  a_p14b: assert property (p14b_no_data_in_t1)
    else $error("P14b violated: write data driven during T1");

  // P15: BRDY# sampled in IDLE with no outstanding cycle produces no rsp_valid.
  property p15_no_spurious_rsp;
    @(posedge clk) disable iff (reset)
      ($past(dbg_state)==S_IDLE && $past(dbg_outstanding)==0 && $past(!brdyn))
        |-> !rsp_valid;
  endproperty
  a_p15: assert property (p15_no_spurious_rsp)
    else $error("P15 violated: spurious rsp_valid in IDLE");

  // -------------------------------------------------------------------------
  // ADS# pulse counter (for P2 beat accounting per scenario)
  // -------------------------------------------------------------------------
  always @(posedge clk) if (!reset && $fell(adsn)) ads_pulses = ads_pulses + 1;

  // count rsp_last seen during a window
  integer last_seen;
  always @(posedge clk) if (!reset && rsp_last) last_seen = last_seen + 1;

  // count req_ack pulses (a request accepted into the FSM). Used by the [FIX-1]
  // corner to prove the 2nd cycle is accepted EXACTLY ONCE (no double-pulse).
  integer ack_pulses;
  always @(posedge clk) if (!reset && req_ack) ack_pulses = ack_pulses + 1;

  // -------------------------------------------------------------------------
  // Directed scenarios
  // -------------------------------------------------------------------------
  integer brdy_count;

  task automatic run_single_read(input [28:0] addr, input [63:0] data);
    begin
      $display("[scenario] single READ  addr=%h", addr);
      beats_seen = 0;
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=0; req_addr=addr; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=data;
      @(posedge clk);              // FSM samples BRDY#
      @(negedge clk); brdyn=1;
      @(posedge clk);
      chk(rsp_data==data, "single read returned correct data");
      tick(2);
    end
  endtask

  task automatic run_single_write(input [28:0] addr, input [63:0] data);
    begin
      $display("[scenario] single WRITE addr=%h", addr);
      @(negedge clk);
      req=1; req_we=1; req_cache=0; req_lock=0; req_addr=addr; req_be=8'hFF; req_wdata=data;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      chk(d_oe==1'b1 && d_out==data, "write drives d_out with d_oe (from T2)");
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
    end
  endtask

  // generic burst at an arbitrary intra-line offset. Checks 4 beats and that the
  // address bus is NOT re-driven during the data beats (a_oe drops after T1).
  task automatic run_burst_fill(input [28:0] addr);
    integer i;
    reg addr_redriven;
    begin
      $display("[scenario] BURST line fill addr=%h (A[4:3]=%0d)", addr, addr[1:0]);
      brdy_count=0; beats_seen=0; addr_redriven=0;
      @(negedge clk);
      req=1; req_we=0; req_cache=1; req_lock=0; req_addr=addr; req_be=8'hFF;
      kenn=0;   // KEN# active => cacheable burst
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      // present 4 BRDY# beats
      for (i=0;i<4;i=i+1) begin
        @(negedge clk); brdyn=0; d_in=64'hA000_0000_0000_0000 + i;
        @(posedge clk);
        if (rsp_valid) beats_seen = beats_seen + 1;
        brdy_count = brdy_count + 1;
        // [FIX-5] during a data beat the address bus must NOT be driven.
        if (a_oe) addr_redriven = 1;
        @(negedge clk); brdyn=1;
        @(posedge clk);
        if (rsp_valid) beats_seen = beats_seen + 1;
      end
      chk(dbg_is_burst==1'b1 || beats_seen>=4, "burst qualified (CACHE#+KEN#)");
      chk(beats_seen==4, "burst returned exactly 4 beats");
      chk(!addr_redriven, "address bus NOT re-driven during burst beats");
      kenn=1;
      tick(2);
    end
  endtask

  task automatic run_locked_rmw(input [28:0] addr, input [63:0] wdata);
    begin
      $display("[scenario] LOCKed RMW pair addr=%h", addr);
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=1; req_split=0; req_addr=addr; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      chk(!lockn, "LOCK# asserted at start of locked read");
      // [FIX-7] aligned 2-cycle locked pair: SCYC must be NEGATED.
      chk(scycn, "SCYC negated for aligned locked pair (read)");
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=64'hDEAD_BEEF_0000_0000;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(1);
      chk(!lockn, "LOCK# still asserted between locked read and write");
      @(negedge clk);
      req=1; req_we=1; req_cache=0; req_lock=1; req_split=0; req_addr=addr; req_be=8'hFF; req_wdata=wdata;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      chk(!lockn, "LOCK# held across the write of the pair");
      chk(scycn, "SCYC negated for aligned locked pair (write)");
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(lockn, "LOCK# de-asserted after locked pair completes");
    end
  endtask

  // [FIX-7] split/misaligned locked group: SCYC must be ASSERTED.
  task automatic run_locked_split(input [28:0] addr, input [63:0] wdata);
    begin
      $display("[scenario] SPLIT (misaligned) LOCKed cycle addr=%h", addr);
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=1; req_split=1; req_addr=addr; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      chk(!lockn && !scycn, "SCYC asserted for misaligned/>2-cycle locked group");
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=64'h0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      // close the locked group with a write
      @(negedge clk);
      req=1; req_we=1; req_cache=0; req_lock=1; req_split=1; req_addr=addr; req_be=8'hFF; req_wdata=wdata;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
    end
  endtask

  task automatic run_pipelined(input [28:0] a0, input [28:0] a1);
    begin
      $display("[scenario] PIPELINED (NA#) a0=%h a1=%h", a0, a1);
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=0; req_addr=a0; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      // assert NA# AND present 2nd request so BIU pipelines
      @(negedge clk); nan=0;
      req=1; req_addr=a1;
      @(posedge clk); while (!req_ack) @(posedge clk);   // 2nd req accepted
      @(negedge clk); req=0; nan=1;
      chk(dbg_outstanding>=2 || ads_pulses>=2, "2nd ADS# issued while 1st outstanding");
      wait (dbg_state==S_T2P);
      @(negedge clk); brdyn=0; d_in=64'h1111_1111_1111_1111;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=64'h2222_2222_2222_2222;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(dbg_outstanding==0, "both pipelined cycles completed");
    end
  endtask

  // [FIX-1] CORNER: NA# coincident with the TERMINATING BRDY# while a 2nd req is
  // ready. The 2nd cycle must be issued exactly once (a single new ADS#), with no
  // double req_ack and no stranded cycle.  We drive NA#+BRDY# on the SAME clock as
  // the (single-beat) cycle's terminating BRDY#, with req held high.
  task automatic run_na_eq_last_brdy(input [28:0] a0, input [28:0] a1);
    integer ads_before, ack_before;
    begin
      $display("[scenario] CORNER: NA# coincident with terminating BRDY# [FIX-1]");
      ads_before = ads_pulses;
      ack_before = ack_pulses;
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=0; req_addr=a0; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);  // 1st cycle accepted (1 ack)
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      // present the SECOND request, then on the SAME clock assert NA# AND the
      // terminating BRDY# of the first cycle.
      @(negedge clk);
      req=1; req_addr=a1;          // 2nd request available
      nan=0; brdyn=0; d_in=64'h3333_3333_3333_3333;  // NA# + terminating BRDY#
      @(posedge clk);              // DUT samples both; must NOT pipeline (last beat)
      @(negedge clk); nan=1; brdyn=1; req=1; req_addr=a1; // keep 2nd req asserted
      // the 2nd cycle should now be launched as a fresh (non-pipelined) cycle:
      @(posedge clk); while (!req_ack) @(posedge clk);  // 2nd cycle accepted (1 ack)
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=64'h4444_4444_4444_4444;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      @(posedge clk);
      chk(rsp_data==64'h4444_4444_4444_4444, "2nd cycle ran exactly once & completed");
      chk((ads_pulses - ads_before)==2, "exactly 2 ADS# total (no double-issue/loss)");
      // [FIX-1] the core handshake must NOT be corrupted: each of the two cycles
      // is accepted by exactly ONE req_ack pulse -> 2 acks total. The buggy
      // racing-st code double-pulses req_ack for the 2nd cycle (3 acks).
      chk((ack_pulses - ack_before)==2, "exactly 2 req_ack pulses (no double-ack)");
      chk(dbg_outstanding==0, "no stranded outstanding cycle after the corner");
      tick(2);
    end
  endtask

  // [FIX-4] CORNER: try to pipeline a 2nd request behind a BURST. The DUT must
  // REFUSE to pipeline (no req_ack for the 2nd) until the burst's 4 beats are
  // done, so the burst is never truncated to 1 beat.
  task automatic run_pipe_behind_burst(input [28:0] aburst, input [28:0] a1);
    integer i;
    reg pipelined_during_burst;
    begin
      $display("[scenario] CORNER: attempt pipeline behind a BURST [FIX-4]");
      pipelined_during_burst=0; beats_seen=0;
      @(negedge clk);
      req=1; req_we=0; req_cache=1; req_lock=0; req_addr=aburst; req_be=8'hFF; kenn=0;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      // present a 2nd request AND assert NA# while the burst runs.
      for (i=0;i<4;i=i+1) begin
        @(negedge clk);
        req=1; req_addr=a1; nan=0;     // tempt the DUT to pipeline
        brdyn=0; d_in=64'hB000_0000_0000_0000 + i;
        @(posedge clk);
        if (rsp_valid) beats_seen=beats_seen+1;
        if (req_ack && dbg_state!=S_T2P && i<3) pipelined_during_burst=1; // accepted mid-burst
        @(negedge clk); brdyn=1; nan=1;
        @(posedge clk);
        if (rsp_valid) beats_seen=beats_seen+1;
      end
      req=0;
      chk(beats_seen==4, "burst delivered all 4 beats (not truncated by pipeline)");
      chk(!pipelined_during_burst, "DUT refused to pipeline behind a burst");
      kenn=1;
      tick(3);
    end
  endtask

  task automatic run_snoop(input [26:0] saddr, input expect_hit, input expect_mod,
                           input inv_v);
    begin
      $display("[scenario] INQUIRE/SNOOP a_in=%h exp_hit=%0d exp_mod=%0d inv=%0d",
               saddr, expect_hit, expect_mod, inv_v);
      @(negedge clk); ahold=1;
      @(posedge clk);
      chk(!a_oe, "AHOLD floats the address bus");
      @(negedge clk); eadsn=0; a_in=saddr; inv=inv_v;
      @(posedge clk);              // EADS# sampled (snoop tracker -> S1)
      @(negedge clk); eadsn=1;
      @(posedge clk);              // SN_S1 -> SN_S2
      @(posedge clk);              // SN_S2 body drives HIT#/HITM#
      @(negedge clk);              // settle the registered outputs before sampling
      if (expect_hit) chk(!hitn, "HIT# asserted 2 clks after EADS# (snoop hit)");
      else            chk( hitn, "HIT# negated after snoop miss");
      if (expect_mod) begin
        chk(!hitmn && wb_req, "HITM# asserted + writeback requested");
        chk(dbg_inv_state==inv_v, "captured INV selects final state (1=I,0=S)");
      end
      ahold=0;
      tick(2);
    end
  endtask

  // [FIX-2] CORNER: inquire hit to a Modified line with INV=1 (invalidating
  // snoop). HITM# + writeback MUST still fire; INV only chooses final state I.
  task automatic run_snoop_modified_inv;
    begin
      $display("[scenario] CORNER: snoop hit-MODIFIED with INV=1 [FIX-2]");
      run_snoop(27'h0BBBB01, 1'b1, 1'b1, 1'b1);  // bit0=1 modified, INV=1
      chk(!hitmn && wb_req, "INV=1 modified-hit still asserts HITM#+writeback");
      // run the actual writeback to clear HITM#
      @(negedge clk);
      req=1; req_we=1; req_wb=1; req_cache=0; req_lock=0;
      req_addr={27'h0BBBB01,2'b00}; req_be=8'hFF; req_wdata=64'hF00D;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0; req_wb=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(hitmn && !wb_req, "HITM# released after the INV=1 writeback completed");
    end
  endtask

  // snoop writeback: after HITM#, run the writeback; HITM# must hold until done.
  task automatic run_snoop_writeback(input [26:0] saddr);
    begin
      $display("[scenario] SNOOP hit-modified -> WRITEBACK (INV=0 => S)");
      run_snoop(saddr, 1'b1, 1'b1, 1'b0);
      chk(!hitmn && wb_req, "HITM# still asserted, writeback pending before WB cycle");
      @(negedge clk);
      req=1; req_we=1; req_wb=1; req_cache=0; req_lock=0; req_addr={saddr,2'b00}; req_be=8'hFF;
      req_wdata=64'hCAFE_F00D_DEAD_C0DE;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0; req_wb=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(hitmn && !wb_req, "HITM# de-asserted after writeback completes");
    end
  endtask

  // [FIX-6] CORNER: after a hit-modified, an UNRELATED core write runs BEFORE
  // the writeback. HITM# must NOT release on that unrelated write.
  task automatic run_unrelated_write_holds_hitm(input [26:0] saddr);
    begin
      $display("[scenario] CORNER: unrelated write must NOT release HITM# [FIX-6]");
      run_snoop(saddr, 1'b1, 1'b1, 1'b0);   // hit-modified -> HITM# asserted
      chk(!hitmn && wb_req, "HITM# asserted after hit-modified");
      // unrelated write (req_wb=0): HITM# must remain asserted
      @(negedge clk);
      req=1; req_we=1; req_wb=0; req_cache=0; req_lock=0; req_addr=29'h0FFFF00; req_be=8'hFF;
      req_wdata=64'hDEAD_0000_0000_0000;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(!hitmn && wb_req, "HITM# STILL asserted after the unrelated write");
      // now the actual writeback releases it
      @(negedge clk);
      req=1; req_we=1; req_wb=1; req_cache=0; req_lock=0; req_addr={saddr,2'b00}; req_be=8'hFF;
      req_wdata=64'hABCD_0000_0000_0000; // value irrelevant for this check
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0; req_wb=0;
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(hitmn && !wb_req, "HITM# released by the actual writeback");
    end
  endtask

  task automatic run_boff;
    begin
      $display("[scenario] BOFF# backoff/restart (single cycle)");
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=0; req_addr=29'h00012345; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); boffn=0;
      @(posedge clk);              // sample BOFF#
      @(posedge clk);              // now floated
      chk(!a_oe && !d_oe && adsn, "BOFF# floated bus and aborted");
      chk(dbg_state==S_BOFF, "FSM in BOFF state");
      @(negedge clk); boffn=1;
      @(posedge clk);              // S_BOFF -> restart edge (drives ADS# via NBA)
      @(negedge clk);              // settle registered outputs before sampling
      chk(!adsn, "restart ADS# issued after BOFF# negated");
      chk(a==29'h00012345, "restarted cycle uses the aborted address");
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=64'h5555_5555_5555_5555;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      @(posedge clk);
      chk(rsp_data==64'h5555_5555_5555_5555, "restarted cycle completed correctly");
      tick(2);
    end
  endtask

  // [FIX-3] CORNER: BOFF# while TWO cycles are outstanding (in T2P). Both must
  // be restarted in their entirety (two ADS#), neither lost.
  task automatic run_boff_two_outstanding(input [28:0] a0, input [28:0] a1);
    integer ads_before;
    begin
      $display("[scenario] CORNER: BOFF# with TWO outstanding (T2P) [FIX-3]");
      ads_before = ads_pulses;
      // build a pipelined pair (reach T2P)
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=0; req_addr=a0; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      @(negedge clk); nan=0; req=1; req_addr=a1;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0; nan=1;
      wait (dbg_state==S_T2P);
      chk(dbg_outstanding==2, "two cycles outstanding in T2P before BOFF#");
      // assert BOFF# in T2P
      @(negedge clk); boffn=0;
      @(posedge clk);
      @(posedge clk);
      chk(dbg_state==S_BOFF && !a_oe && !d_oe, "BOFF# floated bus with 2 outstanding");
      // negate -> both must restart
      @(negedge clk); boffn=1;
      // complete the FIRST restarted cycle
      wait (dbg_state==S_T2);
      chk(a==a0 || dbg_outstanding>=1, "first restarted cycle re-driven (a0)");
      @(negedge clk); brdyn=0; d_in=64'hAAAA_0000_0000_0001;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      // SECOND cycle must follow (re-issued in its entirety)
      wait (dbg_state==S_T2 && dbg_outstanding==1);
      @(negedge clk); brdyn=0; d_in=64'hAAAA_0000_0000_0002;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(dbg_outstanding==0, "BOTH backed-off cycles completed (none lost)");
      chk((ads_pulses-ads_before)>=4, "4 ADS# total: 2 original + 2 restarts");
      tick(2);
    end
  endtask

  // [FIX-8] CORNER: core raises req WHILE AHOLD floats the address bus. The BIU
  // must NOT issue an ADS# (which would drive a floated/invalid address). It must
  // hold the request until AHOLD clears, then launch normally. P7b guards this.
  task automatic run_req_during_ahold(input [28:0] addr, input [63:0] data);
    integer ads_before;
    begin
      $display("[scenario] CORNER: core req while AHOLD active [FIX-8]");
      ads_before = ads_pulses;
      @(negedge clk); ahold=1;
      @(posedge clk);
      chk(!a_oe, "AHOLD floats the address bus (no drive)");
      // raise req while AHOLD is held -- BIU must NOT pulse ADS#
      @(negedge clk); req=1; req_we=0; req_cache=0; req_lock=0; req_addr=addr; req_be=8'hFF;
      tick(3);
      chk(adsn && (ads_pulses==ads_before), "no ADS# issued while AHOLD floats addr");
      chk(dbg_state==S_IDLE, "FSM stayed IDLE under AHOLD with pending req");
      // release AHOLD -> the held request now launches
      @(negedge clk); ahold=0;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      chk(a==addr, "held request launches with correct address after AHOLD clears");
      wait (dbg_state==S_T2);
      @(negedge clk); brdyn=0; d_in=data;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      @(posedge clk);
      chk(rsp_data==data, "post-AHOLD cycle completed correctly");
      tick(2);
    end
  endtask

  task automatic run_hold;
    begin
      $display("[scenario] HOLD / HLDA arbitration");
      @(negedge clk); hold=1;
      @(posedge clk);
      @(posedge clk);
      chk(hlda, "HLDA asserted in response to HOLD");
      chk(!a_oe && !d_oe, "outputs floated during HOLD");
      @(negedge clk); hold=0;
      @(posedge clk);
      @(posedge clk);
      chk(!hlda && dbg_state==S_IDLE, "bus returned (HLDA negated) after HOLD");
      tick(2);
    end
  endtask

  // [FIX-12] HOLD asserted while RESET active: HLDA should be granted.
  task automatic run_hold_during_reset;
    begin
      $display("[scenario] HOLD asserted during RESET [FIX-12]");
      @(negedge clk); hold=1; reset=1;
      @(posedge clk);
      @(posedge clk);
      chk(hlda, "HLDA granted while HOLD held during reset");
      @(negedge clk); reset=0;        // HOLD still high -> stay in hold
      tick(2);
      chk(hlda, "HLDA stays asserted after reset deasserts (HOLD still held)");
      @(negedge clk); hold=0;
      tick(3);
      chk(!hlda && dbg_state==S_IDLE, "bus returned after HOLD released post-reset");
      tick(2);
    end
  endtask

  task automatic run_hold_during_lock(input [28:0] addr);
    begin
      $display("[scenario] HOLD asserted during LOCKed cycle (must not grant)");
      @(negedge clk);
      req=1; req_we=0; req_cache=0; req_lock=1; req_split=0; req_addr=addr; req_be=8'hFF;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      wait (dbg_state==S_T2);
      chk(!lockn, "LOCK# asserted (locked read in progress)");
      @(negedge clk); hold=1;
      @(posedge clk);
      @(negedge clk);
      chk(!hlda, "HLDA NOT granted while LOCK# asserted (HOLD ignored)");
      @(negedge clk); brdyn=0; d_in=64'h7777_7777_7777_7777;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      @(negedge clk);
      req=1; req_we=1; req_cache=0; req_lock=1; req_split=0; req_addr=addr; req_be=8'hFF; req_wdata=64'h8;
      @(posedge clk); while (!req_ack) @(posedge clk);
      @(negedge clk); req=0;
      @(negedge clk);
      chk(!hlda && !lockn, "HLDA still NOT granted during locked write");
      @(negedge clk); brdyn=0;
      @(posedge clk);
      @(negedge clk); brdyn=1;
      tick(2);
      chk(hlda, "HLDA granted once LOCK# released and bus idle");
      @(negedge clk); hold=0;
      tick(3);
      chk(!hlda, "HLDA negated after HOLD released");
    end
  endtask

  // -------------------------------------------------------------------------
  // main
  // -------------------------------------------------------------------------
  initial begin
    errors=0; checks_pass=0; ads_pulses=0; last_seen=0; ack_pulses=0;
    idle_inputs();
    reset=1;
    tick(3);
    @(negedge clk); reset=0;
    tick(2);
    chk(dbg_state==S_IDLE && adsn && lockn && !hlda && !a_oe && !d_oe,
        "post-reset: FSM idle, bus inactive");

    // one scenario per documented bus-cycle type
    run_single_read (29'h01000010, 64'h0123_4567_89AB_CDEF);
    run_single_write(29'h01000020, 64'hFEDC_BA98_7654_3210);
    run_burst_fill  (29'h02000000);                 // line offset A[4:3]=0 (linear)
    run_burst_fill  (29'h02000001);                 // [FIX-5] non-zero offset A[4:3]=1
    run_burst_fill  (29'h02000003);                 // [FIX-5] offset A[4:3]=3
    run_locked_rmw  (29'h03000040, 64'hAABB_CCDD_EEFF_0011);
    run_locked_split(29'h03000044, 64'h00DD_00DD_00DD_00DD);  // [FIX-7] SCYC asserted
    run_pipelined   (29'h04000000, 29'h04000008);

    // snoop set
    run_snoop       (27'h0AAAA02, 1'b1, 1'b0, 1'b1);   // hit, not modified
    run_snoop       (27'h0000000, 1'b0, 1'b0, 1'b1);   // miss
    run_snoop_writeback(27'h0AAAA01);                  // hit-modified, INV=0 (-> S)
    run_snoop_modified_inv();                          // [FIX-2] hit-modified, INV=1 (-> I)
    run_unrelated_write_holds_hitm(27'h0CCCC01);       // [FIX-6]

    // arbitration / abort
    run_boff();
    run_boff_two_outstanding(29'h06000000, 29'h06000008);  // [FIX-3]
    run_hold();
    run_hold_during_reset();                               // [FIX-12]
    run_hold_during_lock(29'h05000080);

    // pipeline / AHOLD corners
    run_na_eq_last_brdy(29'h07000000, 29'h07000008);      // [FIX-1]
    run_pipe_behind_burst(29'h08000000, 29'h08000008);    // [FIX-4]
    run_req_during_ahold(29'h09000000, 64'h9999_9999_9999_9999); // [FIX-8]

    tick(5);
    $display("");
    $display("==================================================================");
    $display("M5B biu_p5 self-consistency summary: %0d checks PASS, %0d FAIL",
             checks_pass, errors);
    if (errors==0) $display("RESULT: ALL GREEN");
    else           $display("RESULT: FAILURES PRESENT");
    $display("==================================================================");
    if (errors!=0) $fatal(1, "biu_p5 testbench FAILED");
    $finish;
  end

  // global timeout
  initial begin
    #200000;
    $display("RESULT: TIMEOUT"); $fatal(1, "timeout");
  end

endmodule

`default_nettype wire
