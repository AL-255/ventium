// bus/biu.sv — Ventium gated BUS SUBSYSTEM (M5B-int).
//
// PLAN.md §6.10 / docs/m5b-bus-spec.md. This is the ADDITIVE, default-OFF
// integration of the standalone pin-level 64-bit P5 bus FSM (`biu_p5`,
// rtl/bus/biu_p5.sv, M5B) into rtl/ + the core, per the M5B-int design.
//
// WHY IT IS GATED / WHY THIS IS THE SAFE SHAPE (the deferral constraint):
// routing the core memory through the pin-level bus CHANGES the memory TIMING
// the core sees. The core's L1-icache LINE FILL (rtl/core/core.sv S_PIPE/S_PF)
// is a cycle-ACCURATE model that assumes the M0 bus-functional contract's
// SAME-CYCLE (combinational) ack (docs/rtl-interface.md §3: "mem_ack single-beat
// handshake, combinational-OK at M0"): its S_PIPE detection clock reads fill
// word-0 and advances ASSUMING that word completed that clock. A genuinely
// multi-cycle ack would drop word-0 and corrupt the fill — and there is NO
// bus-level differential oracle (no real-silicon bus trace) to re-verify any new
// timing against. So integration must be ADDITIVE + GATED + must NOT change the
// memory timing the core observes.
//
// STRUCTURE — the three parts of the loopback bus, wired so the core's memory
// access (a) is driven out the REAL biu_p5 pins (ADS#/A/BE#/M-IO#/D-C#/W-R#/
// D63-0/BRDY#) and (b) a real back-side word returns on the data pins (d_in),
// while the core itself sees the M0-identical same-cycle ack so its fill timing
// is exactly preserved (the deferral-respecting requirement).
//
// biu_p5 here is run STRICTLY AS A PROTOCOL EXERCISER, NOT as a faithful data
// carrier. The core's data and ack come COMBINATIONALLY from the back-side
// memory (mem2_*), fully independent of biu_p5; that path is what is verified
// func-equivalent against the QEMU golden. biu_p5 runs the real ADS#/T1/T2/
// BRDY# pin protocol IN PARALLEL on the same request so its 19 SVA can be
// checked on real core traffic. IMPORTANT — there is NO guarantee that the
// address biu_p5 drives on its pins and the data the loopback returns on d_in
// correspond to the same word: because the core gets a COMBINATIONAL ack, it
// advances to its next access before biu_p5's REGISTERED req_ack pulses, so the
// responder generally replays the core's SUBSEQUENT (not current) back-side
// word. "The data round-trips through the real pin protocol" is true only in
// the sense that SOME real back-side word traverses d_in — it does NOT mean the
// returned word matches the address on the pins or the word the core consumed.
// (This decorrelation does NOT affect any gated result: func-equivalence is
// proven on the independent combinational path, the SVA check protocol TIMING
// not data values, and bus_mode=0 bypasses biu_p5 entirely.)
// The three parts:
//   (1) FRONT adapter   : maps the core 32-bit single-beat mem_* request to the
//                         abstract back-side access (mem2_*) AND to a biu_p5 req.
//   (2) biu_p5 INSTANCE : the verified pin-level FSM (M5B) runs the full
//                         ADS#/T1/T2/BRDY# protocol for this access — its SVA are
//                         checkable in-system on this real traffic (see
//                         verif/bus/biu_p5_sva.sv + the rtl-sva tb build).
//   (3) LOOPBACK pin-level RESPONDER : turns each biu_p5 pin cycle back into the
//                         single abstract back-side access (mem2_*), and drives
//                         the read data back on the data pins (d_in) + BRDY#.
//                         NA#/KEN#/HOLD/BOFF#/AHOLD/EADS# held deasserted, so
//                         biu_p5 stays in single (non-burst/non-pipelined) cycles.
//
// SCOPE / honesty (docs/m5b-bus-spec.md §5.3): SINGLE-CYCLE (non-burst,
// non-pipelined) bridging only. The responder holds KEN# deasserted (biu_p5
// never upgrades a read to a 4-beat line fill), never asserts NA# (no pipeline),
// never asserts HOLD/BOFF#/AHOLD/EADS#. The burst / pipelined / locked-group /
// snoop / backoff / arbitration paths of biu_p5 therefore stay validated ONLY by
// the STANDALONE self-consistency gate (verif/bus/, 19 SVA + 76 directed checks).
// NO pin-level CYCLE oracle exists, so we NEVER claim cycle/pin-exact timing
// through the bus — only that the data round-trips through the real pin protocol
// and the FSM obeys the documented protocol on real core traffic (the SVA hold).

module biu (
    input  logic        clk,
    input  logic        rst_n,          // active-low (the rest of rtl/ uses this)

    // ----- FRONT: core-side 32-bit single-beat mem request (mirrors core.sv) --
    input  logic        c_req,          // core mem_req
    input  logic        c_we,           // core mem_we (1 = write)
    input  logic [31:0] c_addr,         // core mem_addr (byte address)
    input  logic [31:0] c_wdata,        // core mem_wdata
    input  logic [3:0]  c_wstrb,        // core mem_wstrb (per-byte enables)
    output logic [31:0] c_rdata,        // -> core mem_rdata
    output logic        c_ack,          // -> core mem_ack (combinational, M0-timing)

    // ----- BACK: abstract single-beat 32-bit memory (the TB memmodel side) ----
    output logic        m2_req,
    output logic        m2_we,
    output logic [31:0] m2_addr,
    output logic [31:0] m2_wdata,
    output logic [3:0]  m2_wstrb,
    input  logic [31:0] m2_rdata,
    input  logic        m2_ack
);

  // biu_p5 expects synchronous ACTIVE-HIGH reset; rtl/ uses active-low rst_n.
  logic biu_reset;
  assign biu_reset = ~rst_n;

  // ---------------------------------------------------------------------------
  // (1) FRONT adapter — core 32b single-beat mem_* -> the back-side mem2_* access
  //     AND a biu_p5 req. The core sees the M0-IDENTICAL same-cycle ack (so the
  //     cycle-accurate icache fill timing is preserved bit-for-bit); the SAME
  //     access is replayed on the biu_p5 pins for protocol/SVA exercise.
  // ---------------------------------------------------------------------------
  // Address mapping (docs/m5b-bus-spec.md §1): req_addr = A31:A3 = c_addr[31:3].
  // c_addr[2] selects the high (1) / low (0) 32-bit half of the 64-bit beat. For
  // a READ we enable the full addressed-half nibble (the core reads a 32-bit
  // word); for a WRITE we use c_wstrb. The byte enables are placed in the high
  // nibble (bits 7:4) when c_addr[2]=1, else the low nibble (bits 3:0). Write
  // data is the addressed 32-bit half (the other half is 0 — the BEs gate it).
  wire        sel_hi  = c_addr[2];                 // 1 => high 32-bit half
  wire [3:0]  be_nib  = c_we ? c_wstrb : 4'hF;     // read: full word; write: wstrb
  wire [7:0]  req_be  = sel_hi ? {be_nib, 4'h0} : {4'h0, be_nib};
  wire [63:0] req_wd  = sel_hi ? {c_wdata, 32'd0} : {32'd0, c_wdata};

  // The back-side memory (mem2_*) is driven DIRECTLY by the FRONT, combinationally
  // — i.e. EXACTLY the M0 bus-functional contract the core's cycle-accurate icache
  // fill was built against (docs/rtl-interface.md §3). This is what makes the
  // memory TIMING the core observes byte-identical to the direct path, so the
  // M5B deferral constraint (do not change that timing — there is no oracle for a
  // changed one) is respected even in bus_mode=1. c_rdata/c_ack are this
  // combinational back-side path and are FULLY INDEPENDENT of biu_p5 (this is the
  // path verified func-equivalent vs QEMU). The SAME access is also replayed on
  // the biu_p5 pins below for the real pin protocol + SVA exercise — but biu_p5
  // is a PROTOCOL EXERCISER only: the word the responder returns on d_in is NOT
  // guaranteed to be the word at the address biu_p5 drives nor the word the core
  // consumed for this access (see the bus_rdata_q note below). The core never
  // consumes biu_p5's returned data, so this does not affect the functional result.
  // (The M0 BFM is byte-addressable and honours mem_wstrb; mem_addr is passed
  // through verbatim — do NOT re-align — so this is byte-for-byte the direct path.)
  assign m2_req   = c_req;
  assign m2_we    = c_we;
  assign m2_addr  = c_addr;
  assign m2_wdata = c_wdata;
  assign m2_wstrb = c_wstrb;
  assign c_ack    = m2_ack;
  assign c_rdata  = m2_rdata;

  // Latched back-side read word, sampled the clock biu_p5 accepts a request
  // (bp_req_ack), so the responder has a REAL word to replay on the data pins at
  // the cycle's data phase. NOTE (honest, per the M5B-int review): this is NOT
  // the word for the address biu_p5 is driving on its pins. Because the core gets
  // a COMBINATIONAL ack (c_ack = m2_ack), it has already advanced c_addr to its
  // NEXT access by the time biu_p5's REGISTERED bp_req_ack pulses (~1 clock after
  // req is first seen) — so m2_rdata here is generally the core's SUBSEQUENT
  // fetch, not the word at bp_req_addr. The loopback is therefore a protocol
  // EXERCISER (it returns SOME real back-side word so the pin data phase + BRDY#
  // complete and the SVA run), not a faithful addr->data carrier. This is benign:
  // the core's data is c_rdata = m2_rdata (combinational, independent of this
  // register), the SVA check protocol timing not data values, and writes ignore
  // it. There is no pin cycle/data oracle, so no addr<->data correspondence is
  // claimed (docs/m5b-bus-spec.md §5.3).
  logic [31:0] bus_rdata_q;
  always_ff @(posedge clk) begin
    if (!rst_n)              bus_rdata_q <= 32'd0;
    else if (bp_req & bp_req_ack) bus_rdata_q <= m2_rdata;
  end

  // biu_p5 core-side request signals (drive the pins for THIS access)
  wire         bp_req       = c_req;
  wire         bp_req_we    = c_we;
  wire         bp_req_cache = 1'b0;     // never cacheable -> no 4-beat line fill
  wire         bp_req_lock  = 1'b0;     // no locked groups in single-cycle bridging
  wire         bp_req_split = 1'b0;
  wire         bp_req_mio   = 1'b1;     // memory cycle (M/IO# = 1 = memory)
  wire         bp_req_dc    = 1'b1;     // data cycle (D/C# = 1 = data)
  wire [28:0]  bp_req_addr  = c_addr[31:3];
  wire         bp_req_wb    = 1'b0;     // never a snoop-hit writeback

  // biu_p5 core-side responses (observed; the protocol/SVA run on these)
  wire         bp_req_ack;
  wire         bp_rsp_valid;
  wire [63:0]  bp_rsp_data;
  wire         bp_rsp_last;
  wire         bp_wb_req;

  // ---------------------------------------------------------------------------
  // (2) biu_p5 instance — the verified pin-level 64-bit P5 bus FSM (M5B).
  // ---------------------------------------------------------------------------
  logic        pin_adsn, pin_a_oe, pin_mion, pin_dcn, pin_wrn;
  logic        pin_cachen, pin_scycn, pin_lockn, pin_d_oe;
  logic [28:0] pin_a;
  logic [7:0]  pin_be_n;
  logic [63:0] pin_d_out;
  logic        pin_hlda, pin_breq, pin_hitn, pin_hitmn;

  // responder-driven pin inputs
  logic [63:0] rsp_d_in;
  logic        rsp_brdyn;

  // tie-offs: the responder never requests pipelining / cache / arbitration /
  // snoop, so these pin inputs are held DEASSERTED (active-low => 1, active-high
  // => 0). This is what restricts in-system traffic to single-cycle bridging.
  wire        tie_nan   = 1'b1;   // NA#    deasserted (no pipelining)
  wire        tie_kenn  = 1'b1;   // KEN#   deasserted (no burst line fill)
  wire        tie_hold  = 1'b0;   // HOLD   deasserted (no arbitration)
  wire        tie_boffn = 1'b1;   // BOFF#  deasserted (no backoff)
  wire        tie_ahold = 1'b0;   // AHOLD  deasserted (no addr hold)
  wire        tie_eadsn = 1'b1;   // EADS#  deasserted (no snoop)
  wire        tie_inv   = 1'b0;
  wire [26:0] tie_a_in  = 27'd0;

  /* verilator lint_off PINMISSING */
  biu_p5 u_biu_p5 (
      .clk        (clk),
      .reset      (biu_reset),
      // core-side request
      .req        (bp_req),
      .req_we     (bp_req_we),
      .req_cache  (bp_req_cache),
      .req_lock   (bp_req_lock),
      .req_split  (bp_req_split),
      .req_mio    (bp_req_mio),
      .req_dc     (bp_req_dc),
      .req_addr   (bp_req_addr),
      .req_be     (req_be),
      .req_wdata  (req_wd),
      .req_wb     (bp_req_wb),
      .req_ack    (bp_req_ack),
      .rsp_valid  (bp_rsp_valid),
      .rsp_data   (bp_rsp_data),
      .rsp_last   (bp_rsp_last),
      .wb_req     (bp_wb_req),
      // external pins (out)
      .adsn       (pin_adsn),
      .a          (pin_a),
      .a_oe       (pin_a_oe),
      .be_n       (pin_be_n),
      .mion       (pin_mion),
      .dcn        (pin_dcn),
      .wrn        (pin_wrn),
      .cachen     (pin_cachen),
      .scycn      (pin_scycn),
      .lockn      (pin_lockn),
      .d_out      (pin_d_out),
      .d_oe       (pin_d_oe),
      // external pins (in) — driven by the loopback responder / tie-offs
      .d_in       (rsp_d_in),
      .brdyn      (rsp_brdyn),
      .nan        (tie_nan),
      .kenn       (tie_kenn),
      .hold       (tie_hold),
      .hlda       (pin_hlda),
      .boffn      (tie_boffn),
      .breq       (pin_breq),
      .ahold      (tie_ahold),
      .eadsn      (tie_eadsn),
      .inv        (tie_inv),
      .a_in       (tie_a_in),
      .hitn       (pin_hitn),
      .hitmn      (pin_hitmn)
      // dbg_* observability outputs left unconnected
  );
  /* verilator lint_on PINMISSING */

  // ---------------------------------------------------------------------------
  // (3) LOOPBACK pin-level memory RESPONDER.
  // ---------------------------------------------------------------------------
  // Completes each single (non-burst) biu_p5 pin cycle so the FULL pin protocol
  // runs (ADS#/T1/T2/BRDY#) and the bound SVA are checked on real core traffic.
  // It watches the PINS only:
  //   * ADS# (pin_adsn=0) marks T1 of a new cycle.
  //   * the FOLLOWING clock (T2) it asserts BRDY# (rsp_brdyn=0) so biu_p5
  //     completes the single beat, and drives the read data on the data pins
  //     (d_in) from the registered back-side word for THIS access (bus_rdata_q).
  //
  // It does NOT drive mem2_* — the FRONT is the single, combinational mem2 driver
  // (preserving the M0 timing the core needs). The word the responder drives on
  // the data pins (d_in) is bus_rdata_q, a REAL back-side word but generally the
  // core's NEXT access, NOT the word at the address on the pins (see bus_rdata_q
  // above): this loopback is a PROTOCOL EXERCISER, not a faithful addr->data
  // carrier. "The data flows through the real pin protocol" holds only in the
  // sense that the access (addr/BE/data) is driven out the pins and SOME real
  // back-side word returns on d_in to complete the data phase + BRDY# so the SVA
  // run — it is NOT a claim that d_in equals the word at the pin address or the
  // word the core consumed (the core consumes c_rdata combinationally, never
  // d_in). There is no pin cycle/data oracle, so no cycle/correspondence claim is
  // made (docs/m5b-bus-spec.md §5.3).

  logic        r_pend;       // a data beat is pending (we are in T2 this clock)

  always_ff @(posedge clk) begin
    if (!rst_n) r_pend <= 1'b0;
    else begin
      r_pend <= 1'b0;
      // T1: ADS# asserted -> the data phase (T2) is the NEXT clock, where we
      // assert BRDY# + drive d_in to terminate the single beat.
      if (!pin_adsn) r_pend <= 1'b1;
    end
  end

  // BRDY# / d_in: asserted during T2 (registered r_pend stable across the clock).
  // d_in carries the read data in both halves so biu_p5 captures it regardless of
  // the addressed half; for writes d_in is don't-care.
  assign rsp_brdyn = r_pend ? 1'b0 : 1'b1;
  assign rsp_d_in  = {bus_rdata_q, bus_rdata_q};

  // ---------------------------------------------------------------------------
  // Unused-net hygiene: biu_p5 pin outputs that are observed structurally (and by
  // the bound SVA) but not functionally consumed in single-cycle bridging — the
  // float-enables/arbitration/snoop pins are inert here. Keep them referenced so
  // -Wall stays clean without blanket waivers. The biu_p5 bus rsp_* are exercised
  // for the protocol/SVA only; the core's data comes from the combinational
  // back-side path (c_rdata = m2_rdata, M0 timing) and never from biu_p5 — so
  // bp_rsp_data is intentionally unconsumed. Reference them so they are not flagged.
  // ---------------------------------------------------------------------------
  // verilator lint_off UNUSED
  wire _unused = &{1'b0,
                   pin_a, pin_be_n, pin_wrn, pin_d_out,
                   pin_a_oe, pin_mion, pin_dcn, pin_cachen, pin_scycn,
                   pin_lockn, pin_d_oe, pin_hlda, pin_breq, pin_hitn,
                   pin_hitmn, bp_rsp_valid, bp_rsp_last, bp_wb_req,
                   bp_rsp_data};
  // verilator lint_on UNUSED

endmodule : biu
