`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_axi_master.sv — ven_l1d backing port -> AXI4 master (P1-1 step 2).
//
// ven_l1d's backing port (m_*) is WORD-granular: on a line fill it holds m_req
// and walks 8 circular word addresses in a line (the faulting word first, then
// wrapping through the rest of that line), one m_ack per word
// (ven_l1d.sv:99,151,158 — fw advances on EVERY posedge where m_ack==1, with NO
// per-beat valid and NO backpressure); on a write-through it presents one word
// with byte strobes. This module converts that word stream into AXI4 transactions
// to the PS DDR (S_AXI_HPC0_FPD):
//   * READ  (m_we=0): ven_l1d only ever reads during a FILL, and a fill is ALWAYS
//     a full 32-byte line (8 words) — so a backing read is COALESCED into ONE
//     AXI INCR8 or critical-word AXI WRAP8 burst (ARLEN=7). Each
//     returned R beat is handed back as ONE m_ack + m_rdata, in order — exactly the
//     word ven_l1d's fill counter `fw` expects. The single true m_ack rule is
//     `m_ack = (RVALID && RREADY)`: a new word this cycle, m_rdata == that word,
//     m_ack=0 on any bubble cycle (fw then holds and resumes on the next beat).
//   * WRITE (m_we=1): a byte-accurate one- or two-word AXI write.  The P54C has
//     TWO 64-bit write buffers (Intel Pentium Processor Developer's Manual,
//     §2.6): memory stores may retire once admitted to one of those FIFO-ordered
//     buffers, while a later cache-miss read waits until every buffered write has
//     completed on AXI.  This module models exactly that bounded posting point:
//     no unbounded queue, no reordering, and no read-over-write bypass.  A failed
//     BRESP remains a sticky fatal bus error even though the CPU-side store was
//     already accepted, just as an external bus fault cannot be undone by holding
//     the pipe after a posted transaction has retired.
//
// Address remap: the L1 tags/data use the x86 PHYSICAL address; the DDR address is
//   ddr_addr = REMAP_BASE + (phys & ADDR_MASK)  — the whole x86 phys space lands in
// one reserved DDR carveout (REMAP_BASE/ADDR_MASK = the PetaLinux reserved-memory
// node's base/size). The remap is done in ADDR_W width (no 32-bit truncation), and
// REMAP_BASE must be 32-byte aligned so either 32-byte burst shape stays within
// its AXI 4KiB boundary.
//
// Single clock domain (CDC_BYPASS=1, the clean low-risk bring-up): core_clk ==
// axi_clk == the PS PL clock. The async dual-clock CDC variant (core clk vs a
// faster AXI clk via MMCM, an in-repo clean-license 2-FF-Gray async FIFO) is a
// later optimization — a single PL clock to S_AXI_HPC0 is the standard first step.
//
// AXI compliance invariants (the load-bearing ones):
//   * every *VALID is driven from REGISTERED state, never combinational on its
//     *READY (a VALID<-READY comb path deadlocks vs a slave doing READY<-VALID);
//     RREADY/BREADY MAY be combinational on state.
//   * once asserted, *VALID + all its payload hold stable until the handshake.
//   * AW and W handshake INDEPENDENTLY (decoupled done-latches) — never gate WVALID
//     on AWREADY (classic write deadlock vs a W-before-AW slave).
//   * the write-buffer queue is two P54C-sized entries.  AXI B responses may trail
//     issued entries, but a read is held until BOTH the internal entries and every
//     trailing response are gone, preserving P5 strong write ordering.

module ven_axi_master #(
    parameter int unsigned LINE_BEATS = 8,                 // 32B line / 4B word
    parameter int          ADDR_W     = 40,                // PS8 HPC0 master addr
    parameter logic [39:0] REMAP_BASE = 40'h00_0000_0000,  // DDR carveout base
    parameter logic [31:0] ADDR_MASK  = 32'hFFFF_FFFF,     // phys window mask
    parameter logic [3:0]  AXI_ID     = 4'd0,
    // The KV260 integration connects this master only to the reserved DDR
    // carveout. Its non-cacheable RAM reads still use the byte-exact narrow
    // protocol, but are safe to replay; prime those just like line fills so a
    // stale first HP0 response is discarded. Keep 0 for a backing that can
    // contain side-effectful MMIO reads.
    parameter bit          NARROW_REPLAY_SAFE = 1'b0,
    // Backend policy, not an ISA/cache-size option. Leave enabled for HP/HPC
    // targets until their stale-response cause is repaired. A synchronous,
    // ownership-qualified backend may deliver the first cacheable burst.
    // This does not alter the independent narrow/MMIO replay policy above.
    parameter bit          LINE_REPLAY = 1'b1,
    // Timing experiment; generic admission semantics, no caller assumption.
    parameter bit          PARALLEL_WRITE_ADMISSION = 1'b0,
    // #34: per-transaction watchdog. If a read/write makes no progress for WATCHDOG
    // core clocks (a stuck DDR/bridge), the FSM ABORTS — synthesizes the acks ven_l1d
    // expects (so the core never deadlocks) + raises bus_err. Default huge (a normal
    // line fill is <~50 clocks); tests override it small.
    parameter int unsigned WATCHDOG = 1024
) (
    input  logic        core_clk,
    input  logic        core_rst_n,
    input  logic        axi_clk,        // == core_clk in the CDC_BYPASS build
    input  logic        axi_rst_n,      // == core_rst_n in the CDC_BYPASS build

    // ---- backing slave port (driven by ven_l1d's m_* master) ------------------
    input  logic        m_req,
    input  logic        m_we,
    input  logic [31:0] m_addr,
    // REVIEW2_aug2 H-11: this READ is a NARROW, non-cacheable access -- serve it with
    // a 1- or 2-beat burst at the requested word, NOT a 32-byte line fill. A
    // non-cacheable read amplified into eight beats is an MMIO CORRECTNESS bug, not a
    // performance one: read-to-clear registers are cleared eight times over, FIFOs pop
    // repeatedly, and seven neighbouring addresses with unrelated side effects are
    // touched. Ignored for writes (the write path was never a burst).
    // REVIEW1_Aug3 R2-H01: each narrow beat is now its OWN single-beat transaction
    // at a byte-exact address with an exact ARSIZE (m_rd_size: 0=1B, 1=2B, 2=4B),
    // so a device read touches exactly its own bytes. ven_l1d presents one piece
    // per m_req and re-presents after each ack (the standard handshake), so no
    // multi-beat narrow burst (and no 4 KiB-edge split) is ever needed.
    input  logic        m_rd_narrow,
    input  logic [1:0]  m_rd_size,
    input  logic [31:0] m_wdata,
    input  logic [3:0]  m_wstrb,
`ifdef VEN_P54_DUAL_STORE_PAIR
    // Atomic younger store admission. The older m_* store is never acked alone
    // while m_pair_req is asserted; both consume the two P5 slots in U/V order.
    input  logic        m_pair_req,
    input  logic [31:0] m_pair_addr,
    input  logic [31:0] m_pair_wdata,
    input  logic [3:0]  m_pair_wstrb,
    output logic        m_pair_ready,
    output logic        m_pair_ack,
`endif
    output logic [31:0] m_rdata,
    output logic        m_ack,
    output logic        bus_err,        // #34: sticky FATAL fault (timeout or SLVERR/DECERR)

    // ---- clean-shutdown quiesce (so xmutil unloadapp can't wedge the PS interconnect) -
    // shutdown=1: refuse to START any new AXI transaction (the FSMs stop accepting
    // m_req) but COMPLETE any in-flight one (a master can't retract VALID); a backing
    // request that arrives while idle is acked LOCALLY (rdata=0, no DDR access) so the
    // core never deadlocks. Once the in-flight burst/beat finishes, both FSMs sit in
    // IDLE with every AXI *VALID/*READY low — a protocol-clean state the PS can poll
    // (m_idle) before removing the PL overlay. Inert when shutdown=0 (default).
    input  logic        shutdown,
    output logic        m_idle,         // 1 = R_IDLE && W_IDLE -> no outstanding AXI

`ifdef VEN_DBG_CORE
    // ---- read-beat trace (VEN_DBG_CORE): observe each accepted AXI read beat so the
    // on-die ring can post-mortem a corrupted LINE FILL (the F4 board-only fetch bug).
    output logic        dbg_rd_valid,   // 1 = a read beat was accepted this clock
    output logic [31:0] dbg_rd_addr,    // that beat's DDR address (line base + beat*4)
    output logic [31:0] dbg_rd_data,    // that beat's RDATA (raw, off the AXI R bus)
`endif

    // ---- AXI4 master port (-> S_AXI_HPC0_FPD, 32-bit data) --------------------
    // write address channel
    output logic [3:0]        m_axi_awid,
    output logic [ADDR_W-1:0] m_axi_awaddr,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awlock,
    output logic [3:0]        m_axi_awcache,
    output logic [2:0]        m_axi_awprot,
    output logic [3:0]        m_axi_awqos,
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,
    // write data channel
    output logic [31:0]       m_axi_wdata,
    output logic [3:0]        m_axi_wstrb,
    output logic              m_axi_wlast,
    output logic              m_axi_wvalid,
    input  logic              m_axi_wready,
    // write response channel
    input  logic [3:0]        m_axi_bid,
    input  logic [1:0]        m_axi_bresp,
    input  logic              m_axi_bvalid,
    output logic              m_axi_bready,
    // read address channel
    output logic [3:0]        m_axi_arid,
    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arlock,
    output logic [3:0]        m_axi_arcache,
    output logic [2:0]        m_axi_arprot,
    output logic [3:0]        m_axi_arqos,
    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,
    // read data channel
    input  logic [3:0]        m_axi_rid,
    input  logic [31:0]       m_axi_rdata,
    input  logic [1:0]        m_axi_rresp,
    input  logic              m_axi_rlast,
    input  logic              m_axi_rvalid,
    output logic              m_axi_rready
);

`ifndef SYNTHESIS
  // elaboration guards: convert two silent-corruption bugs into build failures.
  initial begin
    if (REMAP_BASE[4:0] != 5'd0)
      $fatal(1, "ven_axi_master: REMAP_BASE must be 32-byte aligned (INCR8 4KiB rule)");
    if (LINE_BEATS != 8)
      $fatal(1, "ven_axi_master: LINE_BEATS must be 8 (ven_l1d 32B line)");
  end
`endif

  // remap an x86 physical address into the reserved DDR window, in ADDR_W width.
  function automatic logic [ADDR_W-1:0] remap(input logic [31:0] a);
    remap = REMAP_BASE + ADDR_W'(a & ADDR_MASK);
  endfunction

  // REVIEW1_Aug3 R2-H01: the lane mask of the current narrow piece -- the
  // (1<<rsize_q) addressed bytes at the byte lane araddr_q[1:0].
  logic [31:0] narrow_mask;
  always_comb begin
    automatic int unsigned nb;
    nb = 32'd1 << rsize_q;                      // 1, 2, or 4 bytes
    narrow_mask = ((32'h1 << (nb * 8)) - 32'h1) << {araddr_q[1:0], 3'b000};
  end

  // REVIEW2 M-07: when ADDR_MASK is narrower than 32 bits (the KV260 build folds the
  // whole 4 GiB into a 256 MiB carveout), every physical address sharing the low mask
  // bits COLLIDES -- guest RAM above the window, PCI apertures and high aliases all
  // land on unrelated low memory. That is a platform memory-map LIMIT, and the design
  // is safe only because the supported guest keeps its accesses inside the window
  // apart from the BIOS shadow the fold deliberately catches.
  //
  // A compile-time check is not possible: guest RAM size is configured by the PS at
  // RUNTIME, not by a parameter. So the configuration is REJECTED AT THE ACCESS --
  // any request whose address has bits outside ADDR_MASK, other than the BIOS shadow
  // the fold deliberately catches, raises a STICKY error that feeds bus_err.
  //
  // This replaces a simulation-only $display. That was a notification, not a
  // rejection: it was invisible in synthesis, so on real hardware an aliased access
  // corrupted unrelated low memory silently. M-07's required direction is to "reject
  // unsupported RAM/aperture configurations", and bus_err is how this design already
  // reports a fatal bus fault (the core's bus_err -> S_HALT path), so an out-of-window
  // access now HALTS LOUDLY instead of scribbling on someone else's memory.
  //
  // alias_ok is the supported envelope: everything inside the mask, plus the
  // top-of-4G BIOS shadow that the fold exists to serve.
  logic alias_err;   // sticky: an access was folded onto a DIFFERENT physical address
  logic alias_bad;
  // REVIEW1_Aug2 H-04: validate the whole request EXTENT, not just its first byte.
  // This checked m_addr alone. An unaligned access whose first byte is inside the mask
  // can still need a SECOND aligned beat at remap({m_addr[31:2],2'b00} + 4), computed
  // independently further down -- so with the KV260 256 MiB mask a dword starting near
  // 0x0FFF_FFFF passed the check while its second beat wrapped to the carveout base and
  // scribbled on low memory. The H-07 work proved rejection for a bad STARTING address
  // only, which is exactly the hole.
  //
  // REVIEW2_aug2 H-15: "+7 always" was WRONG in the safe direction-turned-unsafe. The
  // second beat EXISTS only when the request actually spills past lane 3; assuming it
  // unconditionally rejected legal accesses at the top of the window -- a 4-byte access
  // at 0x0FFF_FFFC under the deployed 0x0FFF_FFFF mask is entirely inside it, but the
  // hypothetical second word is not. Worse, ven_l1d walks m_addr through a 32-byte line
  // fill word by word, so the FINAL word of a fill that began fully inside the window
  // tripped the sticky alias_err.
  //
  // Mirror the datapath's OWN second-beat condition (the W_IDLE arm below): the extra
  // beat is issued iff the strobe, shifted by the byte offset, spills past lane 3. For
  // a read the master fetches 4 bytes at the byte address, so it needs the second word
  // iff the address is unaligned. Deriving the check from the same expression that
  // generates the beat is the point -- an independently-written bound is what produced
  // this bug.
  //
  // A byte-exact narrow read (m_rd_narrow) is different again: the piece is one
  // aligned power-of-two single-beat transaction of (1<<m_rd_size) bytes, so it can
  // never need a second word at all, and its true extent is m_addr+size-1 -- the
  // legacy word-window logic rejected byte/word reads wholly inside the RAM window's
  // last word (a 2-byte read at the top-2 bytes "spilled" to word_base+7 and wedged
  // the requester with a false alias_err).
  logic [7:0]  alias_ssh;
  logic        alias_two;
  logic [31:0] alias_last;
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic [7:0] pair_alias_ssh;
  logic [31:0] pair_alias_last;
  logic pair_alias_bad;
`endif
  assign alias_ssh  = {4'd0, m_wstrb} << m_addr[1:0];
  assign alias_two  = m_we ? (alias_ssh[7:4] != 4'd0)
                    : m_rd_narrow ? 1'b0
                    : (m_addr[1:0] != 2'b00);
  assign alias_last = (m_rd_narrow && !m_we)
                    ? (m_addr + ((32'd1 << m_rd_size) - 32'd1))
                    : {m_addr[31:2], 2'b00} + (alias_two ? 32'd7 : 32'd3);
  assign alias_bad = m_req && !(m_addr >= 32'hFFFE_0000)
                           && ( ((m_addr     & ~ADDR_MASK) != 32'd0)
                             || ((alias_last & ~ADDR_MASK) != 32'd0) )
`ifdef VEN_P54_DUAL_STORE_PAIR
      || pair_alias_bad
`endif
      ;
`ifdef VEN_P54_DUAL_STORE_PAIR
  assign pair_alias_ssh = {4'd0, m_pair_wstrb} << m_pair_addr[1:0];
  assign pair_alias_last = {m_pair_addr[31:2], 2'b00} +
                           ((pair_alias_ssh[7:4] != 4'd0) ? 32'd7 : 32'd3);
  assign pair_alias_bad = m_req && m_we && m_pair_req &&
                          !(m_pair_addr >= 32'hFFFE_0000) &&
                          (((m_pair_addr & ~ADDR_MASK) != 32'd0) ||
                           ((pair_alias_last & ~ADDR_MASK) != 32'd0));
`endif
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) alias_err <= 1'b0;
    else if (alias_bad) begin
      alias_err <= 1'b1;
`ifndef SYNTHESIS
`ifdef VEN_P54_DUAL_STORE_PAIR
      if (pair_alias_bad)
        $display("[AXI] M-07 PAIR ALIAS: addr=%08h extent=%08h outside ADDR_MASK=%08h. Raising bus_err.",
                 m_pair_addr, pair_alias_last, ADDR_MASK);
      else
`endif
      $display("[AXI] M-07 ALIAS: addr=%08h has bits outside ADDR_MASK=%08h -- would fold onto %08h, which belongs to a different physical address. Raising bus_err.",
               m_addr, ADDR_MASK, (m_addr & ADDR_MASK));
`endif
    end
  end

  // ---- READ FSM (coalesced cache-line fill) ---------------------------------
  // REVIEW2 M-08: R_DRAIN deterministically resynchronises the R channel after an
  // RLAST/beat-count mismatch (see the R_DATA arm).
  typedef enum logic [2:0] { R_IDLE, R_AR, R_DATA, R_DRAIN, R_FAULT } rstate_e;
  rstate_e          rst;
  logic [ADDR_W-1:0] araddr_q;     // first beat address (registered, stable)
  logic              rwrap_q;      // cache fill starts away from word 0 -> AXI WRAP8
  logic [7:0]        r_beat;       // accepted-R-beat counter (exit on count, not RLAST)
  // HP0 DOUBLE-READ (port of the proven ven_ddram_axi build-#31 workaround): the PS S_AXI_HP
  // async DDR read FIFO can return a STALE prior burst. PROVEN on the VEN path too: with a
  // daemon-injected BDA key resident in DDR (kbd head!=tail), the guest's INT16 buffer peek
  // read head==tail through a FLUSHED L1D — the fill itself returned stale data — freezing
  // the retire comparator on the empty branch (f000:0x490e) while DDR held the key. Issue
  // every line fill TWICE at the same address: the FIRST (priming) burst is DISCARDED, the
  // SECOND is delivered. 2x fill latency; correctness over speed (ao486 runs this way).
  //
  // STATUS: OPEN workaround, not a repair. The stale-burst root cause (HP/HPC
  // reset, CDC, outstanding-ID, or channel-drain sequencing) is unidentified;
  // until it is root-caused and proven on the board, the double fill is the
  // default and VEN_SINGLE_FILL stays an opt-in diagnostic. The cost is real:
  // doubled DDR read traffic and cold-miss service time on every cacheable
  // line fill.
  //
  // REVIEW_Aug3 C-01: by default the workaround applies to cacheable line fills
  // only. A narrow read may be device/MMIO, where replay would duplicate a read
  // side effect, so it starts primed and its first burst is delivered. The KV260
  // no-L2 router is different: this master can reach only its reserved DDR
  // carveout, while device regions are rejected/routed outside it. Enabling
  // NARROW_REPLAY_SAFE there also primes non-cacheable RAM reads, preventing the
  // same stale first HP0 response from corrupting reset-state (CR0.CD=1) IVT and
  // stack accesses. The generic default remains side-effect safe.
  logic              rd_primed;    // 0 = priming (discard) burst; 1 = the real (delivered) burst
  // REVIEW1_Aug3 R2-H01: the latched ARSIZE of the current read transaction
  // (0=1B, 1=2B, 2=4B) and whether it is a narrow piece (those get their rdata
  // masked to the addressed lanes and are primed only when replay is proven safe).
  logic [1:0]        rsize_q;
  logic              narrow_q;
  logic              rresp_err;    // sticky: a read beat returned non-OKAY RRESP
  // A response bearing another master's ID, or appearing when this master owns
  // no matching response phase, is not merely an errored completion.  It cannot
  // be associated safely with an outstanding request.  The terminal fault state
  // drains the AXI channel without advancing the fill/write accounting, then
  // requires the normal coupled-reset recovery path to resynchronise the fabric.
  logic              rid_err;      // sticky: R channel ID/ownership protocol fault
  // REVIEW2 M-08: RLAST disagreeing with the beat count is a PROTOCOL VIOLATION by
  // the slave. Exiting on the beat count (below) is the right defensive choice -- an
  // early RLAST must not freeze ven_l1d's fill mid-line -- but silently tolerating
  // the mismatch means an early RLAST leaves the master waiting for beats the slave
  // considers sent, and a late/missing one lets it return idle and potentially launch
  // a new transaction over an incomplete burst. Neither is recoverable by guessing.
  // Make it a sticky FATAL bus error so the core halts deterministically instead of
  // running on data the bus never agreed about. A compliant slave never sets this.
  logic              rlast_err;    // sticky: RLAST did not match the beat count
  logic              bresp_err;    // sticky: a write returned non-OKAY BRESP
  logic              bid_err;      // sticky: B channel ID/ownership protocol fault
  logic              wd_err_r;     // sticky: a READ watchdog timeout aborted (read-FF driven)
  logic              wd_err_w;     // sticky: a WRITE watchdog timeout aborted (write-FF driven)
  logic [15:0]       r_wd, w_wd;   // #34 read/write watchdog cycle counters (since last progress)
  // A response failure is only recorded into the sticky flags at the active clock
  // edge.  The backing/L1 acknowledgement, however, is consumed on that *same*
  // edge.  Keep raw handshake-time fault terms so an erroneous R beat is never
  // presented as data before its sticky error can become visible.  `fatal_now`
  // also blocks a same-edge new request when a BRESP fails; already admitted
  // writes continue draining so clean shutdown cannot strand a retained P5 slot.
  logic              r_hs, rlast_exp, r_bad_now, b_bad_now;
  logic              rid_bad_now, bid_bad_now, r_unowned_now, b_unowned_now;
  logic              rproto_bad_now, bproto_bad_now;
  logic              fatal_latched, fatal_now, rd_deliver;
`ifndef SYNTHESIS
`ifdef VEN_AXI_ADMISSION_PERF
  // Simulation-only accounting for the R_IDLE admission predicate. A line
  // fill may legally wait behind retained P54C stores; price that barrier
  // explicitly before considering any read-after-write ordering change.
  longint unsigned perf_rd_candidate;
  longint unsigned perf_rd_admitted;
  longint unsigned perf_rd_block_rproto;
  longint unsigned perf_rd_block_shutdown;
  longint unsigned perf_rd_block_hold;
  longint unsigned perf_rd_block_alias;
  longint unsigned perf_rd_block_fatal;
  longint unsigned perf_rd_block_write;
`endif
`endif

  // ---- write->read landing barrier (build-#21 class, CORE path) ---------------
  // The CPU write-through's BVALID fires BEFORE the store lands in PS-DDR (HP0 posted). A
  // line FILL issued a few instructions later (in-order) BEATS the store to DDR and caches
  // stale bytes — fine-timing proved the Win95 AH=87 GDT CS-descriptor store lands in DDR the
  // same t it's read as 0. HOLD a fill of a JUST-WRITTEN line for WRBAR cycles so the posted
  // store lands first. SAME-LINE only: fetches + other-line reads are never held (no global
  // slowdown), and wr_cd re-arms on every write so back-to-back GDT stores extend the window.
  localparam logic [7:0] WRBAR = 8'd0;   // DIAGNOSTIC build: barrier DISABLED (didn't help; slowed boot)
  logic [26:0] wr_line; logic [7:0] wr_cd;
  wire rd_hold = (wr_cd != 8'd0) && (m_addr[31:5] == wr_line);
  // This retained landing-barrier state is part of the same reset domain as the
  // write FSM below; reset it asynchronously with the coupled AXI seam.
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)                         begin wr_line <= 27'd0; wr_cd <= 8'd0; end
    else if (m_req && m_we && !shutdown && !alias_bad) begin wr_line <= m_addr[31:5]; wr_cd <= WRBAR; end  // C-01/H-07
    else if (wr_cd != 8'd0)                        wr_cd   <= wr_cd - 8'd1;
  end

  // ---- P54C WRITE BUFFERS (two FIFO entries, decoupled AXI AW/W) --------------
  // A core store is byte-addressed: the byte at m_addr is lane 0 of m_wstrb/m_wdata.
  // Mapped onto a 32-bit AXI bus it occupies lanes [boff .. boff+nbytes-1]; when that
  // range spills past lane 3 (an unaligned 16/32-bit store, e.g. a dword to ..0x..2)
  // the store straddles TWO 32-bit words (word A = m_addr&~3, word B = +4).
  //
  // P54C (not P55C/MMX) has exactly TWO one-quadword write buffers.  Keep this a
  // local constant rather than a feature/profile knob: the hardware configuration is
  // one P5 model, and a larger generic queue would both hide ordering mistakes and
  // make the implementation unlike the target processor.  The queue stores CPU
  // writes before lane alignment; an entry stays occupied until the LAST response
  // for its final AXI beat.  AXI B responses therefore cannot accumulate behind an
  // arbitrarily large hidden interconnect queue (see R_IDLE below).
  localparam int unsigned P5_WBUF_DEPTH = 2;
  localparam int unsigned WBUF_PTRW = $clog2(P5_WBUF_DEPTH);
  localparam int unsigned WBUF_CNTW = $clog2(P5_WBUF_DEPTH + 1);
  localparam int unsigned B_CNTW    = $clog2((P5_WBUF_DEPTH * 2) + 1);

  typedef enum logic { W_IDLE, W_RUN } wstate_e;
  wstate_e          wst;
  logic [31:0]       wq_addr [P5_WBUF_DEPTH];
  logic [31:0]       wq_wdata[P5_WBUF_DEPTH];
  logic [3:0]        wq_wstrb[P5_WBUF_DEPTH];
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  logic [P5_WBUF_DEPTH-1:0] wq_fused;
  logic [31:0]       wq_hi_data[P5_WBUF_DEPTH];
  logic              wr_fused_q, wr_quad_enq, pair_quad_ok;
`endif
  logic [WBUF_PTRW-1:0] wq_rp, wq_wp;
  logic [WBUF_CNTW-1:0] wq_count;
  logic [1:0]        wq_bcount[P5_WBUF_DEPTH]; // issued AXI write responses per P5 slot
  logic [P5_WBUF_DEPTH-1:0] wq_issued;         // final AXI beat accepted for this slot
  logic                 wr_enq, wr_dispatch, wr_busy, wr_dispatch_slot;
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic                 wr_pair_enq;
  logic                 wr_can_pair;
`endif
  logic                 wr_active_slot, b_owner_slot, b_owner_valid, wq_head_release;
  logic [63:0]          q_dsh;
  logic [7:0]           q_ssh;
  logic                 wr_active;
  logic [B_CNTW-1:0]    b_outstanding;
  logic                 aw_hs, w_hs, b_hs, b_retire_hs;
  logic                 wr_beat_sent, wr_resp_issue, wr_store_final, wr_progress;
`ifdef VEN_AXI_READ_ON_FINAL_B
  logic                 rd_last_b_now;
`endif

  // REVIEW2_aug2 H-11: the read burst's beat count, LATCHED with araddr_q at accept.
  // It used to be the constant LINE_BEATS, which is why the L1D could not ask for a
  // narrower access however it addressed the request -- the master decided, and it
  // always decided "a whole line". Everything downstream (arlen, the r_beat terminal
  // compare, the priming re-issue) now reads this instead of the constant, so the two
  // cannot disagree about how long the burst is.
  logic [8:0]        rbeats_q;
  logic [ADDR_W-1:0] awaddr_q;       // current beat's word-aligned AXI address
  logic [31:0]       wdata_q;        // current beat's data (lane-shifted)
  logic [3:0]        wstrb_q;        // current beat's strobe (lane-shifted)
  logic [ADDR_W-1:0] awaddr2_q;      // beat B address (m_addr&~3 + 4)
  logic [31:0]       wdata2_q;       // beat B data  (high 32 of the 64-bit shift)
  logic [3:0]        wstrb2_q;       // beat B strobe (high 4  of the 8-bit shift)
  logic              xword_q;        // 1 = the store straddles a word -> need beat B
  logic              wbeat;          // 0 = beat A in flight, 1 = beat B in flight
  logic              aw_done, w_done;  // independent handshake latches

  // A write admission is the CPU-facing completion point.  q_count is the P54C
  // occupancy, not a mere launch queue: it includes unissued, active, and
  // response-pending stores.  A second slot may begin draining while the oldest
  // waits for B, but no third CPU write can be admitted before the oldest slot's
  // final response returns.  On that exact B handshake the released slot may be
  // refilled immediately: rejecting it until the following clock creates an
  // artificial bubble in a full P5 queue, even though the architectural depth
  // never exceeds two.  This keeps the AXI interconnect from silently becoming
  // an unbounded extension of the two architectural write buffers.
  always_comb begin
    wr_dispatch       = 1'b0;
    wr_dispatch_slot  = wq_rp;
    // A wrong/unowned BID is a terminal fabric fault.  Existing AW/W VALID must
    // still complete (AXI VALID cannot be retracted), but do not LAUNCH another
    // buffered store once the fault is observed.  Matching BRESP errors retain
    // their historical drain behavior; only the ambiguous-ID case is terminal.
    if (!bid_err && !bproto_bad_now && !wr_active &&
        (wq_count != WBUF_CNTW'(0))) begin
      if (!wq_issued[wq_rp]) begin
        wr_dispatch = 1'b1;
      end else if ((wq_count == WBUF_CNTW'(P5_WBUF_DEPTH)) &&
                   !wq_issued[~wq_rp]) begin
        // Oldest slot has launched and is awaiting B; the second P5 slot can
        // drain concurrently, but still remains occupied until ITS B response.
        wr_dispatch      = 1'b1;
        wr_dispatch_slot = ~wq_rp;
      end
    end
`ifdef VEN_P54_WBUF_PIPE_DISPATCH
    // The final W beat of one occupied P5 slot releases the AXI issue
    // registers, not the architectural slot (that still waits for B).  Load
    // an already-queued younger slot on this edge so its AW/W can launch on
    // the next clock.  Never dispatch a same-edge enqueue: its payload is not
    // registered yet, and the queue must remain exactly two slots deep.
    if (!bid_err && !bproto_bad_now && wr_store_final &&
        (wq_count == WBUF_CNTW'(P5_WBUF_DEPTH)) &&
        !wq_issued[~wr_active_slot]) begin
      wr_dispatch      = 1'b1;
      wr_dispatch_slot = ~wr_active_slot;
    end
`endif

    q_dsh = {32'd0, wq_wdata[wr_dispatch_slot]} <<
            {wq_addr[wr_dispatch_slot][1:0], 3'b000};
    q_ssh = {4'd0,  wq_wstrb[wr_dispatch_slot]} <<
            wq_addr[wr_dispatch_slot][1:0];

    b_outstanding = B_CNTW'(wq_bcount[0]) + B_CNTW'(wq_bcount[1]);
    b_owner_slot  = wq_rp;
    b_owner_valid = 1'b0;
    if ((wq_count != WBUF_CNTW'(0)) && (wq_bcount[wq_rp] != 2'd0)) begin
      b_owner_valid = 1'b1;
    end else if ((wq_count == WBUF_CNTW'(P5_WBUF_DEPTH)) &&
                 (wq_bcount[~wq_rp] != 2'd0)) begin
      b_owner_slot  = ~wq_rp;
      b_owner_valid = 1'b1;
    end

    // The oldest P5 slot may be released only after it has launched its final
    // beat AND every B response for that (possibly straddling) store has arrived.
    // Fold the current edge's issue/B handshakes into the test so same-cycle
    // completion is never lost.
    wq_head_release = 1'b0;
    if (wq_count != WBUF_CNTW'(0)) begin
      automatic logic [1:0] head_b_after;
      automatic logic       head_final_after;
      head_b_after = wq_bcount[wq_rp];
      if (wr_resp_issue && (wr_active_slot == wq_rp)) head_b_after = head_b_after + 2'd1;
      if (b_retire_hs && b_owner_valid && (b_owner_slot == wq_rp))
        head_b_after = head_b_after - 2'd1;
      head_final_after = wq_issued[wq_rp] ||
                         (wr_store_final && (wr_active_slot == wq_rp));
      wq_head_release = head_final_after && (head_b_after == 2'd0);
    end
  end
`ifdef VEN_P54_DUAL_STORE_PAIR
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  // Only forward adjacent, aligned, full dwords.  In particular, swapping
  // their physical order in a burst would violate P54 strong write ordering.
  // The address hint is independent of m_pair_req so ready has no feedback.
  assign pair_quad_ok = (m_addr[2:0] == 3'd0) &&
                        (m_pair_addr[31:3] == m_addr[31:3]) &&
                        (m_pair_addr[2:0] == 3'd4) &&
                        (m_wstrb == 4'hf) && (m_pair_wstrb == 4'hf);
`endif
  // Two free slots are required atomically. A same-edge head B may contribute
  // one slot, but a full queue with only one released slot cannot accept a pair.
  assign wr_can_pair = (wq_count == WBUF_CNTW'(0)) ||
                       ((wq_count == WBUF_CNTW'(1)) && wq_head_release);
  // Credit is independent of m_pair_req. The core uses it to fall back to
  // ordinary serial U/V issue when only one write-buffer slot is available;
  // waiting for a second slot would make the dual-store path slower.
  assign m_pair_ready = !fatal_now &&
                        ((shutdown && m_idle) ||
                         (!shutdown && (rst == R_IDLE) &&
`ifdef VEN_P54_WBUF_QUAD_COMBINE
                          (wr_can_pair || (pair_quad_ok &&
                           ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release)))));
`else
                          wr_can_pair));
`endif
  generate if (PARALLEL_WRITE_ADMISSION) begin : g_parallel_write
    // Write extent is independent of direction, request, and pair selection.
    // Keep the original exact spill and high-BIOS-shadow rules, even for
    // generic masks and held, currently uncredited producer requests.
    logic [31:0] write_alias_last;
    logic write_alias_bad, pair_write_alias_bad;
    assign write_alias_last = {m_addr[31:2], 2'b00} +
                              ((alias_ssh[7:4] != 4'd0) ? 32'd7 : 32'd3);
    assign write_alias_bad = !(m_addr >= 32'hFFFE_0000) &&
                             (((m_addr & ~ADDR_MASK) != 32'd0) ||
                              ((write_alias_last & ~ADDR_MASK) != 32'd0));
    assign pair_write_alias_bad = !(m_pair_addr >= 32'hFFFE_0000) &&
                                  (((m_pair_addr & ~ADDR_MASK) != 32'd0) ||
                                   ((pair_alias_last & ~ADDR_MASK) != 32'd0));
    // Preserve these two cut points through synthesis. In particular, do
    // not merge m_req/m_we/m_pair_req back into extent or credit arithmetic.
    // A readiness predicate is NOT an ACK and never mutates retained state.
    (* keep = "true" *) logic single_admit, pair_admit;
    assign single_admit = (rst == R_IDLE) && !shutdown && !fatal_now &&
                          !write_alias_bad &&
                          ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release);
    assign pair_admit = (rst == R_IDLE) && !shutdown && !fatal_now &&
                        !write_alias_bad && !pair_write_alias_bad &&
                        (wr_can_pair
`ifdef VEN_P54_WBUF_QUAD_COMBINE
                         || (pair_quad_ok &&
                             ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release))
`endif
                        );
    assign wr_enq = m_req && m_we && (m_pair_req ? pair_admit : single_admit);
`ifndef SYNTHESIS
    logic original_enq;
  assign original_enq      = (rst == R_IDLE) && m_req && m_we && !shutdown &&
                       !alias_bad && !fatal_now &&
                       (m_pair_req ? (wr_can_pair
`ifdef VEN_P54_WBUF_QUAD_COMBINE
                                     || (pair_quad_ok &&
                                        ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release))
`endif
                                     ) :
                        ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release));
    always_ff @(posedge core_clk) if (core_rst_n)
      assert (wr_enq === original_enq)
        else $fatal(1, "PARALLEL-WRITE: changed admission");
`endif
  end else begin : g_original_write
  assign wr_enq      = (rst == R_IDLE) && m_req && m_we && !shutdown &&
                       !alias_bad && !fatal_now &&
                       (m_pair_req ? (wr_can_pair
`ifdef VEN_P54_WBUF_QUAD_COMBINE
                                     || (pair_quad_ok &&
                                        ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release))
`endif
                                     ) :
                        ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release));
  end endgenerate
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  assign wr_quad_enq = wr_enq && m_pair_req && pair_quad_ok;
  assign wr_pair_enq = wr_enq && m_pair_req && !pair_quad_ok;
`else
  assign wr_pair_enq = wr_enq && m_pair_req;
`endif
  // Quiesce acknowledges requests locally without issuing AXI; do so for
  // both pair members together, matching the established single-store rule.
  assign m_pair_ack  = !fatal_now &&
                       ((wr_enq && m_pair_req) ||
                        (shutdown && m_idle && m_req && m_we && m_pair_req));
`else
  assign wr_enq      = (rst == R_IDLE) && m_req && m_we && !shutdown && !alias_bad && !fatal_now &&
                       ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release);
`endif
  assign wr_busy     = wr_active || (wq_count != WBUF_CNTW'(0));
  assign wst         = wr_busy ? W_RUN : W_IDLE;
`ifdef VEN_AXI_READ_ON_FINAL_B
  // On the edge that accepts the FINAL B response, the older P54 write slot
  // is empty before a newly registered ARVALID can appear. Start R_AR on that
  // edge instead of spending an extra R_IDLE clock observing the old count.
  // A younger queued write, an in-flight AW/W, or an errored B still blocks.
  assign rd_last_b_now = (wq_count == WBUF_CNTW'(1)) &&
                         !wr_active && wq_head_release && b_retire_hs;
`endif

`ifdef VEN_P54_WBUF_ADMIT_DISPATCH
  // Accept into the existing AXI launch registers when they become free,
  // but only after every older retained slot has issued its complete payload.
  // An already queued unissued store always wins (wr_dispatch). The old final
  // beat and its B accounting still use the pre-edge slot. The newly admitted
  // store takes its ordinary ring slot and remains there until its final B.
  // No new queue depth, combinational AXI VALID or read-order bypass.
  wire wr_head_payload_done = wq_issued[wq_rp] ||
      (wr_store_final && wr_active_slot == wq_rp);
  wire wr_second_payload_done = wq_issued[~wq_rp] ||
      (wr_store_final && wr_active_slot != wq_rp);
  wire wr_empty_dispatch = wr_enq && (!wr_active || wr_store_final) &&
      !wr_dispatch && ((wq_count == WBUF_CNTW'(0)) ||
       (wr_head_payload_done && ((wq_count == WBUF_CNTW'(1)) || wr_second_payload_done)));
  wire wr_launch = wr_dispatch || wr_empty_dispatch;
  wire wr_launch_slot = wr_empty_dispatch ? wq_wp : wr_dispatch_slot;
  wire [31:0] wr_launch_addr = wr_empty_dispatch ? m_addr : wq_addr[wr_dispatch_slot];
  // Select the unaligned payload first, then share one byte-lane shifter.
  // Do not duplicate the old queue aligner for the live enqueue path.
  wire [31:0] wr_launch_raw_data = wr_empty_dispatch ? m_wdata : wq_wdata[wr_dispatch_slot];
  wire [3:0] wr_launch_raw_strb = wr_empty_dispatch ? m_wstrb : wq_wstrb[wr_dispatch_slot];
  wire [63:0] wr_launch_data = {32'd0, wr_launch_raw_data} << {wr_launch_addr[1:0], 3'b000};
  wire [7:0] wr_launch_strb = {4'd0, wr_launch_raw_strb} << wr_launch_addr[1:0];
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  wire wr_launch_fused = wr_empty_dispatch ? wr_quad_enq : wq_fused[wr_dispatch_slot];
  wire [31:0] wr_launch_hi = wr_empty_dispatch ? m_pair_wdata : wq_hi_data[wr_dispatch_slot];
`endif
`endif

  // ---- AXI combinational drive ----------------------------------------------
  always_comb begin
    // read address channel.  WRAP8 fills still remain within one 32-byte line.
    m_axi_arid    = AXI_ID;
    m_axi_araddr  = araddr_q;
    m_axi_arlen   = 8'(rbeats_q - 9'd1);  // H-11: latched length (LINE_BEATS, or 1 narrow)
    // R2-H01: exact ARSIZE for narrow device pieces (1B/2B/4B); fills are 4B.
    m_axi_arsize  = {1'b0, rsize_q};      // AXI encoding matches rsize_q 0/1/2
    // A cache-line fill whose first requested word is not word zero uses a
    // legal AXI WRAP8 burst.  That returns the critical word first while still
    // enumerating precisely the same 32-byte line; narrow reads always remain
    // single-beat INCR transactions.  rwrap_q is latched with araddr_q, so the
    // priming replay repeats the identical burst shape.
    m_axi_arburst = rwrap_q ? 2'b10 : 2'b01; // WRAP / INCR
    m_axi_arlock  = 1'b0;
    m_axi_arcache = 4'b0011;             // Normal NON-cacheable bufferable: the BD uses NON-coherent
                                         // HP0, and cacheable attrs legally let the SmartConnect width
                                         // converter serve reads from PREVIOUSLY FETCHED data — the
                                         // stale-read source (PS-written DDR invisible to the guest).
    m_axi_arprot  = 3'b000;
    m_axi_arqos   = 4'd0;
    m_axi_arvalid = (rst == R_AR);
    // RREADY is a registered-state-only response sink.  Do NOT make READY depend
    // combinationally on RID/VALID: AXI forbids input->output interface paths and
    // a wrong response must still be drainable.  R_FAULT consumes traffic after an
    // ID/ownership fault but never returns it to the L1 or resumes normal state.
    m_axi_rready  = (rst == R_DATA) || (rst == R_DRAIN) || (rst == R_FAULT);

    // write address channel — one aligned 4-byte beat from the active P5 buffer.
    m_axi_awid    = AXI_ID;
    m_axi_awaddr  = awaddr_q;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
    m_axi_awlen   = wr_fused_q ? 8'd1 : 8'd0;
`else
    m_axi_awlen   = 8'd0;
`endif
    m_axi_awsize  = 3'b010;
    m_axi_awburst = 2'b01;
    m_axi_awlock  = 1'b0;
    m_axi_awcache = 4'b0011;             // (same rationale as arcache — never mark HP0 traffic cacheable)
    m_axi_awprot  = 3'b000;
    m_axi_awqos   = 4'd0;
    m_axi_awvalid = wr_active && !aw_done;
    // write data channel
    m_axi_wdata   = wdata_q;
    m_axi_wstrb   = wstrb_q;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
    m_axi_wlast   = !wr_fused_q || wbeat;
`else
    m_axi_wlast   = 1'b1;                 // single-beat write
`endif
    m_axi_wvalid  = wr_active && !w_done;
    // write response channel.  Normal BREADY is occupancy-only.  After an
    // ID/ownership fault it remains asserted to drain the response channel, but
    // b_retire_hs below prevents every such beat from releasing a write slot.
    // This stays free of AXI input->output combinational paths.
    m_axi_bready  = (b_outstanding != B_CNTW'(0)) || bid_err;

    // backing response: a read beat hands RDATA back as one m_ack; the write acks on
    // BVALID. On a watchdog timeout the AXI handshake is HELD (a master cannot retract
    // VALID — AXI has no cancel), bus_err is raised, and the core's bus_err->S_HALT
    // override abandons the stuck access + halts (the PS then resets). No protocol-
    // violating abort, no drain.
    // clean-shutdown quiesce: both FSMs idle == no outstanding AXI (every *VALID is
    // gated on a non-IDLE state above, so IDLE is the protocol-safe drained state).
    // This is meaningful only for the planned shutdown protocol. An independently
    // asserted reset clears local bookkeeping and may have aborted posted traffic,
    // so the reset seam must never be treated as a clean-drain acknowledgement.
    // A response-ID/ownership fault is terminal until the coupled core/AXI reset
    // path.  Do not advertise a clean quiesce merely because a foreign response
    // was physically drained.  (Owned RRESP/BRESP errors still use normal drain.)
    m_idle  = (rst == R_IDLE) && (wst == W_IDLE) &&
              !rid_err && !bid_err && !rproto_bad_now && !bproto_bad_now;
    // a backing request that arrives while shutting-down + idle is acked locally with
    // rdata=0 (NO AXI transaction is started — the FSM start arms are gated on
    // !shutdown), so the core/L1 never deadlocks waiting for an ack we won't issue.
    // REVIEW1_Aug3 R2-H01: mask a narrow piece's rdata to the addressed byte lanes
    // (AXI leaves the other lanes undefined) so ven_l1d can OR-merge the pieces.
    m_rdata = (shutdown && m_idle) ? 32'd0
            : narrow_q ? (m_axi_rdata & narrow_mask) : m_axi_rdata;
    // A write acks when it enters one of the two P54C write buffers.  Its AW/W
    // beats remain FIFO ordered, BRESP is still checked, and R_IDLE below blocks
    // every read until all admitted writes have completed.  This is posting, not a
    // speculative write: the bounded buffer is the retained architectural state.
    m_ack   = !fatal_now && (rd_deliver ||                 // deliver ONLY a good real burst
                                               // (a fill's 2nd; a narrow read's 1st/only — C-01)
                              wr_enq ||
                              (shutdown && m_idle && m_req)); // shutdown: local ack, no DDR
    bus_err = fatal_now; // #34 + M-08 + M-07, including the current bad AXI handshake
  end

  assign aw_hs       = m_axi_awvalid && m_axi_awready;
  assign w_hs        = m_axi_wvalid  && m_axi_wready;
  assign b_hs        = m_axi_bvalid  && m_axi_bready;
  // Observe malformed response ownership independently of READY.  The fixed-ID
  // master must never see a different ID.  A matching-ID response before this
  // master has issued/owned a response phase is also terminal: it is stale or
  // misrouted, and must not be inherited by a later transaction.  The one
  // unavoidable limitation of a single reusable AXI ID is a stale matching-ID
  // response that appears *during* a newly owned response phase; a conforming
  // interconnect cannot create that ambiguity, and the coupled reset contract
  // handles an already-detected fabric fault.
  assign rid_bad_now = m_axi_rvalid && (m_axi_rid != AXI_ID);
  assign bid_bad_now = m_axi_bvalid && (m_axi_bid != AXI_ID);
  // An R response is not owned until an AR handshake has completed on a prior
  // clock edge.  In particular, RVALID concurrent with an R_AR/ARREADY edge is
  // still stale or misrouted: state has not entered R_DATA yet and RREADY is
  // deliberately low.  Treating that cycle as owned would let a matching-ID
  // stale beat survive into R_DATA and be consumed as the new request's data.
  assign r_unowned_now = m_axi_rvalid && ((rst == R_IDLE) || (rst == R_AR));
  assign b_unowned_now = m_axi_bvalid && (b_outstanding == B_CNTW'(0)) && !bid_err;
  assign rproto_bad_now = rid_bad_now || r_unowned_now;
  assign bproto_bad_now = bid_bad_now || b_unowned_now;
  assign r_hs        = (rst == R_DATA) && m_axi_rvalid && m_axi_rready;
  assign rlast_exp   = (r_beat == 8'(rbeats_q - 9'd1));
  assign r_bad_now   = rproto_bad_now ||
                       (r_hs && ((m_axi_rresp != 2'b00) || (m_axi_rlast != rlast_exp)));
  assign b_bad_now   = bproto_bad_now || (b_hs && (m_axi_bresp != 2'b00));
  assign fatal_latched = wd_err_r | wd_err_w | rresp_err | rid_err |
                         bresp_err | bid_err | rlast_err | alias_err;
  assign fatal_now   = fatal_latched | r_bad_now | b_bad_now;
  assign rd_deliver  = r_hs && rd_primed && !fatal_now;
  assign b_retire_hs = b_hs && !bid_err && !bproto_bad_now;
  assign wr_beat_sent = wr_active && (aw_done || aw_hs) && (w_done || w_hs);
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  assign wr_resp_issue = wr_beat_sent && (!wr_fused_q || wbeat);
`else
  assign wr_resp_issue = wr_beat_sent;
`endif
  assign wr_store_final = wr_beat_sent && (wbeat || !xword_q);
  assign wr_progress = wr_enq || wr_dispatch || aw_hs || w_hs || b_hs;

`ifdef VEN_DBG_CORE
  // read-beat trace taps: capture the address + data of every ACCEPTED read beat.
  assign dbg_rd_valid = rd_deliver;  // real, error-free burst only
  assign dbg_rd_addr  = rwrap_q
                      ? {araddr_q[31:5], araddr_q[4:2] + r_beat[2:0], 2'b00}
                      :  araddr_q[31:0] + {22'd0, r_beat, 2'b00};
  assign dbg_rd_data  = m_axi_rdata;
`endif

  // ---- READ sequencing -------------------------------------------------------
  // The enclosing seam couples core_rst_n to axi_rst_n.  Async assertion must
  // quiesce held ARVALID/RREADY and terminal response-fault state even if AXI
  // reset falls between core clock edges.
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      rst <= R_IDLE; araddr_q <= '0; rwrap_q <= 1'b0; r_beat <= 8'd0;
      rresp_err <= 1'b0; rid_err <= 1'b0; rlast_err <= 1'b0;
      rbeats_q <= 9'(LINE_BEATS); rsize_q <= 2'd2; narrow_q <= 1'b0;
      r_wd <= 16'd0; wd_err_r <= 1'b0; rd_primed <= 1'b0;
`ifndef SYNTHESIS
`ifdef VEN_AXI_ADMISSION_PERF
      perf_rd_candidate <= 64'd0;
      perf_rd_admitted <= 64'd0;
      perf_rd_block_rproto <= 64'd0;
      perf_rd_block_shutdown <= 64'd0;
      perf_rd_block_hold <= 64'd0;
      perf_rd_block_alias <= 64'd0;
      perf_rd_block_fatal <= 64'd0;
      perf_rd_block_write <= 64'd0;
`endif
`endif
    end else begin
      // A wrong/unowned R response may handshake because RREADY is deliberately
      // state-only.  Latch it immediately, but never retract an ARVALID that is
      // already held in R_AR: AXI requires that address VALID/payload stay stable
      // until ARREADY accepts them.  Once that compulsory AR handshake completes,
      // enter R_FAULT without executing normal fill/replay accounting.
      if (rproto_bad_now) rid_err <= 1'b1;
`ifndef SYNTHESIS
`ifdef VEN_AXI_ADMISSION_PERF
      if ((rst == R_IDLE) && m_req && !m_we) begin
        perf_rd_candidate <= perf_rd_candidate + 64'd1;
        // Keep this priority identical to the R_IDLE fault/start arms so the
        // displayed buckets sum to candidate cycles exactly.
        if (rproto_bad_now)
          perf_rd_block_rproto <= perf_rd_block_rproto + 64'd1;
        else if (shutdown)
          perf_rd_block_shutdown <= perf_rd_block_shutdown + 64'd1;
        else if (rd_hold)
          perf_rd_block_hold <= perf_rd_block_hold + 64'd1;
        else if (alias_bad)
          perf_rd_block_alias <= perf_rd_block_alias + 64'd1;
        else if (fatal_now)
          perf_rd_block_fatal <= perf_rd_block_fatal + 64'd1;
        else if (wr_busy
`ifdef VEN_AXI_READ_ON_FINAL_B
                 && !rd_last_b_now
`endif
                )
          perf_rd_block_write <= perf_rd_block_write + 64'd1;
        else
          perf_rd_admitted <= perf_rd_admitted + 64'd1;
      end
`endif
`endif
      unique case (rst)
        // REVIEW_aug2 H-07: an ALIASING request must be REJECTED, not merely recorded.
        // alias_err was sticky and fed bus_err, but neither FSM start tested it -- the
        // same clock that recorded the error latched the remapped address, so a write
        // went out through AW/W/B and could corrupt the aliased LOW DDR location before
        // the delayed bus_err halted the core. That is detection, not rejection.
        // Gating the start means no AXI transaction is ever launched for an out-of-
        // window address; bus_err still halts the core, exactly as the #34 watchdog does.
        R_IDLE: if (rproto_bad_now) begin
                  rst  <= R_FAULT;
                  r_wd <= 16'd0;
                end else if (m_req && !m_we && !shutdown && !rd_hold && !alias_bad && !fatal_now &&
`ifdef VEN_AXI_READ_ON_FINAL_B
                             (!wr_busy || rd_last_b_now)) begin
`else
                             !wr_busy) begin
`endif
                  // REVIEW2_aug2 H-11: a CACHEABLE backing read is a full line fill and
                  // latches the 32B-aligned base, as before. A NARROW read is ONE
                  // single-beat transaction at the byte-exact address with an exact
                  // ARSIZE (REVIEW1_Aug3 R2-H01): ven_l1d presents each aligned
                  // power-of-two piece separately, so there is never a multi-beat
                  // narrow burst and never a 4 KiB-edge split to make.
                  if (m_rd_narrow) begin
                    araddr_q <= remap(m_addr);
                    rbeats_q <= 9'd1;
                    rsize_q  <= m_rd_size;
                    narrow_q <= 1'b1;
                    rwrap_q  <= 1'b0;
                  end else begin
                    // ven_l1d presents a circular cache-line stream whose
                    // beat zero is the faulting aligned word.  Preserve that
                    // word here and select WRAP8 when it is not line word 0.
                    // AXI WRAP8 is 32 bytes, so it cannot cross a 4 KiB page.
                    araddr_q <= remap({m_addr[31:2], 2'd0});
                    rbeats_q <= 9'(LINE_BEATS);
                    rsize_q  <= 2'd2;               // fills are always 4B beats
                    narrow_q <= 1'b0;
                    rwrap_q  <= (m_addr[4:2] != 3'd0);
                  end
                  r_beat <= 8'd0; r_wd <= 16'd0;
`ifdef VEN_SINGLE_FILL
                  // EXPERIMENT ONLY (task #24). Skips the priming burst so a fill costs ONE
                  // burst instead of two. NOT SAFE TO SHIP as-is: the priming read exists
                  // because the PS S_AXI_HP async read FIFO returned a STALE prior burst and
                  // froze the guest (see the header comment). This define exists to MEASURE
                  // the payoff of fixing that root cause, not to work around it.
                  rd_primed <= 1'b1;
`else
                  // A narrow read is replayed only when the integration proves the
                  // AXI target is ordinary memory. Otherwise deliver its first and
                  // only transaction so a device side effect executes exactly once.
                  rd_primed <= m_rd_narrow ? !NARROW_REPLAY_SAFE : !LINE_REPLAY;
`endif
                  rst <= R_AR;
                end
        R_AR:   if (m_axi_arready) begin
                  // If an earlier bad R arrived while ARREADY was low, this
                  // handshake is mandatory for AXI legality but its response is
                  // terminally discarded rather than treated as a fresh fill.
                  rst <= (rid_err || rproto_bad_now) ? R_FAULT : R_DATA;
                  r_wd <= 16'd0;
                end
                else if (rid_err || rproto_bad_now) r_wd <= 16'd0;
                // #34 watchdog: a stall of WATCHDOG cycles with no progress -> raise
                // the sticky fault (bus_err) but HOLD arvalid (AXI: VALID can't retract).
                else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;
                else r_wd <= r_wd + 16'd1;
        R_DATA: if (rproto_bad_now) begin
                  rst  <= R_FAULT;
                  r_wd <= 16'd0;
                end else if (r_hs) begin       // beat accepted (progress)
                  // DEFENSIVE: exit on the BEAT COUNT vs ARLEN, NOT a (possibly
                  // mis-asserted) RLAST — a non-compliant slave's early RLAST then
                  // cannot freeze ven_l1d's fill mid-line. Identical timing for a
                  // compliant slave (RLAST lands exactly at r_beat==rbeats_q-1, the
                  // rlast_align SVA below checks it). Sticky-flag a non-OKAY RRESP.
                  if (m_axi_rresp != 2'b00)        rresp_err <= 1'b1;
                  // M-08: RLAST must be high exactly on the final beat. Flagging the
                  // mismatch (sticky -> bus_err) is only half of what the review asks
                  // for; the other half is to RECOVER DETERMINISTICALLY rather than
                  // leave the channel in an unknown state.
                  // REVIEW_Aug3 C-01: "the final beat" is rbeats_q-1, NOT the constant
                  // LINE_BEATS-1. This used to compare against the constant, so a
                  // COMPLIANT narrow (1- or 2-beat) response — RLAST on beat 0 or 1 —
                  // was misclassified as an EARLY RLAST: sticky bus_err on every MMIO
                  // read, and the FSM bailed before ven_l1d's bypass got its beats.
                  if (m_axi_rlast != rlast_exp) rlast_err <= 1'b1;
                  if (m_axi_rlast && !rlast_exp) begin
                    // EARLY RLAST: the slave has ENDED the burst, so the beats this
                    // master is still counting will never arrive. Previously the FSM
                    // sat here until the #34 watchdog fired -- a timeout, not a defined
                    // recovery. Terminate now; bus_err is already sticky, so the core
                    // halts on a known cycle instead of an arbitrary one.
                    r_beat <= 8'd0; rst <= R_IDLE;
                  end else if (rlast_exp) begin
                    if (!m_axi_rlast) begin
                      // LATE RLAST: our count is satisfied but the slave still owes
                      // beats. Returning to IDLE here would let the NEXT AR be issued
                      // while those beats are in flight, and they would be consumed as
                      // the new burst's data -- silent cross-transaction corruption.
                      // Drain to the real RLAST first.
                      rst <= R_DRAIN;
                    end else if (!rd_primed && !fatal_now) begin
                      // priming burst done (all beats DISCARDED): re-issue the SAME
                      // burst (araddr_q preserved); the second one is delivered.
                      rd_primed <= 1'b1; r_beat <= 8'd0; rst <= R_AR;
                    end else rst <= R_IDLE;                       // real burst complete
                  end else r_beat <= r_beat + 8'd1;
                  r_wd <= 16'd0;
                end

                else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;  // #34 stall watchdog
                else r_wd <= r_wd + 16'd1;

        // M-08: consume the remaining beats of an over-long burst until the slave's
        // real RLAST, then return to IDLE with the channel resynchronised. The #34
        // watchdog still backstops a slave that never asserts RLAST at all.
        R_DRAIN: if (rproto_bad_now) begin
                   rst  <= R_FAULT;
                   r_wd <= 16'd0;
                 end else if (m_axi_rvalid && m_axi_rready) begin
                   if (m_axi_rlast) begin r_beat <= 8'd0; rst <= R_IDLE; end
                   r_wd <= 16'd0;
                 end
                 else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;
                 else r_wd <= r_wd + 16'd1;
        // Terminal ID/ownership fault: channel handshakes are intentionally
        // discarded so a foreign response cannot clog the shared interconnect,
        // but state/accounting never returns to normal without reset.
        R_FAULT: if (m_axi_rvalid && m_axi_rready) r_wd <= 16'd0;
        default: rst <= R_IDLE;
      endcase
    end
  end

  // ---- WRITE-buffer sequencing ----------------------------------------------
  // CPU-facing enqueue, FIFO dispatch, AXI transfer, and B response retirement
  // are deliberately separate.  Dispatch does NOT dequeue: the entry remains in
  // the P54C-sized FIFO until its final B response, so a read cannot bypass it.
  // Match the read-side asynchronous reset contract so AW/W VALID, BREADY and
  // retained P5 write state cannot outlive an AXI-only reset.
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      wq_rp <= '0; wq_wp <= '0; wq_count <= '0;
      for (int i = 0; i < P5_WBUF_DEPTH; i++) begin
        wq_addr[i] <= '0; wq_wdata[i] <= '0; wq_wstrb[i] <= '0;
        wq_bcount[i] <= 2'd0;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
        wq_fused[i] <= 1'b0; wq_hi_data[i] <= '0;
`endif
      end
      wq_issued <= '0;
      wr_active <= 1'b0;
      wr_active_slot <= 1'b0;
      awaddr_q <= '0; wdata_q <= 32'd0; wstrb_q <= 4'd0;
      awaddr2_q <= '0; wdata2_q <= 32'd0; wstrb2_q <= 4'd0;
      xword_q <= 1'b0; wbeat <= 1'b0; aw_done <= 1'b0; w_done <= 1'b0;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
      wr_fused_q <= 1'b0;
`endif
      bresp_err <= 1'b0; bid_err <= 1'b0; w_wd <= 16'd0; wd_err_w <= 1'b0;
    end else begin
      // Only B-retirement releases a P54C slot.  Dispatch is deliberately NOT a
      // dequeue: a slot stays counted from CPU admission through its final B.
      // An enqueue plus a head release can share the ring in one edge.
`ifdef VEN_P54_DUAL_STORE_PAIR
      wq_count <= wq_count + WBUF_CNTW'(wr_enq) +
                  WBUF_CNTW'(wr_pair_enq) - WBUF_CNTW'(wq_head_release);
`else
      unique case ({wr_enq, wq_head_release})
        2'b10: wq_count <= wq_count + WBUF_CNTW'(1);
        2'b01: wq_count <= wq_count - WBUF_CNTW'(1);
        default: ;
      endcase
`endif
      if (wr_enq) begin
        wq_addr[wq_wp]  <= m_addr;
        wq_wdata[wq_wp] <= m_wdata;
        wq_wstrb[wq_wp] <= m_wstrb;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
        wq_fused[wq_wp] <= wr_quad_enq;
        wq_hi_data[wq_wp] <= m_pair_wdata;
`endif
        wq_bcount[wq_wp] <= 2'd0;
        wq_issued[wq_wp] <= 1'b0;
`ifdef VEN_P54_DUAL_STORE_PAIR
        wq_wp <= wq_wp + WBUF_PTRW'(1) + WBUF_PTRW'(wr_pair_enq);
`else
        wq_wp <= wq_wp + WBUF_PTRW'(1);
`endif
      end
`ifdef VEN_P54_DUAL_STORE_PAIR
      if (wr_pair_enq) begin
        wq_addr[~wq_wp] <= m_pair_addr;
        wq_wdata[~wq_wp] <= m_pair_wdata;
        wq_wstrb[~wq_wp] <= m_pair_wstrb;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
        // A non-fused pair allocates both slots.  The second slot can retain
        // sidecar state from an earlier fused owner after B retirement; clear
        // it at allocation so this single word cannot emit a stale second W.
        wq_fused[~wq_wp] <= 1'b0;
        wq_hi_data[~wq_wp] <= 32'd0;
`endif
        wq_bcount[~wq_wp] <= 2'd0;
        wq_issued[~wq_wp] <= 1'b0;
      end
`endif
      if (wq_head_release) wq_rp <= wq_rp + WBUF_PTRW'(1);
`ifdef VEN_P54_WBUF_ADMIT_DISPATCH
      if (wr_launch) begin
        // BYTE-LANE ALIGN (P2 fix): the core's byte zero is shifted onto the
        // matching AXI word lane.  An unaligned 16/32-bit store can spill into
        // exactly one following word; both beats remain adjacent in FIFO order.
        awaddr_q  <= remap({wr_launch_addr[31:2], 2'b00});
        wdata_q   <= wr_launch_data[31:0];
        wstrb_q   <= wr_launch_strb[3:0];
        awaddr2_q <= remap({wr_launch_addr[31:2], 2'b00} + 32'd4);
        wdata2_q  <= wr_launch_data[63:32];
        wstrb2_q  <= wr_launch_strb[7:4];
        xword_q   <= (wr_launch_strb[7:4] != 4'd0);
`ifdef VEN_P54_WBUF_QUAD_COMBINE
        wr_fused_q <= wr_launch_fused;
        if (wr_launch_fused) begin
          wdata2_q <= wr_launch_hi;
          wstrb2_q <= 4'hf;
          xword_q <= 1'b1;
        end
`endif
        wbeat     <= 1'b0;
        aw_done   <= 1'b0;
        w_done    <= 1'b0;
        wr_active <= 1'b1;
        wr_active_slot <= wr_launch_slot;
      end

`else
      if (wr_dispatch) begin
        // BYTE-LANE ALIGN (P2 fix): the core's byte zero is shifted onto the
        // matching AXI word lane.  An unaligned 16/32-bit store can spill into
        // exactly one following word; both beats remain adjacent in FIFO order.
        awaddr_q  <= remap({wq_addr[wr_dispatch_slot][31:2], 2'b00});
        wdata_q   <= q_dsh[31:0];
        wstrb_q   <= q_ssh[3:0];
        awaddr2_q <= remap({wq_addr[wr_dispatch_slot][31:2], 2'b00} + 32'd4);
        wdata2_q  <= q_dsh[63:32];
        wstrb2_q  <= q_ssh[7:4];
        xword_q   <= (q_ssh[7:4] != 4'd0);
`ifdef VEN_P54_WBUF_QUAD_COMBINE
        wr_fused_q <= wq_fused[wr_dispatch_slot];
        if (wq_fused[wr_dispatch_slot]) begin
          wdata2_q <= wq_hi_data[wr_dispatch_slot];
          wstrb2_q <= 4'hf;
          xword_q <= 1'b1;
        end
`endif
        wbeat     <= 1'b0;
        aw_done   <= 1'b0;
        w_done    <= 1'b0;
        wr_active <= 1'b1;
        wr_active_slot <= wr_dispatch_slot;
      end

`endif

      // AW and W complete independently (either order).  A beat becomes an AXI
      // outstanding write only after BOTH handshakes, so BREADY can never consume
      // a response without a matching accepted command.
      if (wr_active) begin
        if (aw_hs) aw_done <= 1'b1;
        if (w_hs)  w_done  <= 1'b1;
        if (wr_beat_sent) begin
          if (!wbeat && xword_q) begin
            // Second word of the same architectural store.  It cannot be interleaved
            // with another store, preserving byte order across the word boundary.
`ifdef VEN_P54_WBUF_QUAD_COMBINE
            if (!wr_fused_q) awaddr_q <= awaddr2_q;
`else
            awaddr_q <= awaddr2_q;
`endif
            wdata_q  <= wdata2_q;
            wstrb_q  <= wstrb2_q;
            wbeat    <= 1'b1;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
            aw_done  <= wr_fused_q;
`else
            aw_done  <= 1'b0;
`endif
            w_done   <= 1'b0;
          end else begin
            // A same-edge pipelined dispatch has already loaded the next
            // registered AW/W payload above.  It must stay active; the old
            // slot's final W/B accounting below still uses old ownership.
`ifdef VEN_P54_WBUF_ADMIT_DISPATCH
            if (!wr_launch) wr_active <= 1'b0;
`else
            if (!wr_dispatch) wr_active <= 1'b0;
`endif
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
          end
        end
      end

      // AXI4 orders B responses for one ID.  Matching-ID completions retire in
      // that order and matching BRESP faults retain the normal drain behavior.
      // An ID/ownership fault may still handshake to keep AXI live, but it never
      // decrements B accounting or releases a P5 slot; bid_err makes that state
      // terminal until reset.
      if (bproto_bad_now) bid_err <= 1'b1;
      if (b_retire_hs && m_axi_bresp != 2'b00) bresp_err <= 1'b1;
      for (int i = 0; i < P5_WBUF_DEPTH; i++) begin
        // A full-queue B response may free wq_wp and admit a new CPU store on
        // the same edge.  Its freshly allocated response count must remain zero;
        // applying the OLD owner's B retirement after the allocation would wrap
        // it to three and make the new entry permanently busy.
        if (!(wr_enq && (wq_wp == WBUF_PTRW'(i)))
`ifdef VEN_P54_DUAL_STORE_PAIR
            && !(wr_pair_enq && (~wq_wp == WBUF_PTRW'(i)))
`endif
            ) begin
          unique case ({wr_resp_issue && (wr_active_slot == WBUF_PTRW'(i)),
                       b_retire_hs && b_owner_valid && (b_owner_slot == WBUF_PTRW'(i))})
            2'b10: wq_bcount[i] <= wq_bcount[i] + 2'd1;
            2'b01: wq_bcount[i] <= wq_bcount[i] - 2'd1;
            default: ;
          endcase
        end
      end
      // Same ownership rule as bcount above.  It is unreachable for the normal
      // FIFO schedule, but makes a replacement edge robust if an implementation
      // later permits a completion and reuse of the same slot together.
      if (wr_store_final && !(wr_enq && (wq_wp == wr_active_slot))
`ifdef VEN_P54_DUAL_STORE_PAIR
          && !(wr_pair_enq && (~wq_wp == wr_active_slot))
`endif
          )
        wq_issued[wr_active_slot] <= 1'b1;

      // One progress watchdog covers queue dispatch, independent AW/W handshakes,
      // and B retirement.  It retains the old safety property: a hung AXI target
      // raises bus_err while all asserted VALID signals remain protocol-compliant.
      if (!wr_busy && !wr_enq) w_wd <= 16'd0;
      else if (wr_progress)    w_wd <= 16'd0;
      else if (w_wd >= 16'(WATCHDOG)) wd_err_w <= 1'b1;
      else w_wd <= w_wd + 16'd1;
    end
  end

`ifndef SYNTHESIS
  // ---- bound protocol checks (VALID stability, burst legality, ordering) -----
  // VALID held with stable payload until the handshake.
  ar_stable: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_arvalid && !m_axi_arready) |=> (m_axi_arvalid && $stable(m_axi_araddr)
                                             && $stable(m_axi_arlen) && $stable(m_axi_arburst)));
  aw_stable: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_awvalid && !m_axi_awready) |=>
      (m_axi_awvalid && $stable(m_axi_awaddr) && $stable(m_axi_awlen) &&
       $stable(m_axi_awsize) && $stable(m_axi_awburst)));
  // W payload stable independent of AW (decoupling check).
  w_stable:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_wvalid && !m_axi_wready) |=> (m_axi_wvalid && $stable(m_axi_wdata)
                                           && $stable(m_axi_wstrb) && $stable(m_axi_wlast)));
  // Burst start alignment, by burst SHAPE (REVIEW_Aug3 C-01): a normal line
  // fill starts on a 32B boundary, while a critical-word WRAP8 starts on any
  // 4B-aligned dword of its 32B line.  A narrow piece is exactly SIZE-aligned
  // to its own ARSIZE (REVIEW1_Aug3 R2-H01) — its whole point is to address the
  // requested bytes, not a line or even a word base.
  ar_align:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> (narrow_q
                         ? ((m_axi_araddr[1:0] & (2'b11 >> (2'd2 - rsize_q))) == 2'd0)
                         : (rwrap_q ? (m_axi_araddr[1:0] == 2'd0)
                                    : (m_axi_araddr[4:0] == 5'd0))));
  wrap_shape: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_arvalid && rwrap_q) |->
      (m_axi_arburst == 2'b10 && rbeats_q == 9'(LINE_BEATS) && rsize_q == 2'd2 && !narrow_q));
`ifndef SYNTHESIS
  // debug tap (cosim bring-up): print the offending AR when ar_align fires.
  // Negedge: the fatal assert's $stop at the posedge would preempt a posedge tap.
  always @(negedge core_clk)
    if (core_rst_n && m_axi_arvalid &&
        !(narrow_q ? ((m_axi_araddr[1:0] & (2'b11 >> (2'd2 - rsize_q))) == 2'd0)
                   : (rwrap_q ? (m_axi_araddr[1:0] == 2'd0)
                              : (m_axi_araddr[4:0] == 5'd0))))
      $display("[ARALIGN] araddr=%h narrow=%b rsize=%0d rbeats=%0d m_addr=%h m_size=%0d m_narrow=%b",
               m_axi_araddr, narrow_q, rsize_q, rbeats_q, m_addr, m_rd_size, m_rd_narrow);
`endif
  // The burst's actual extent never crosses 4 KiB.  A WRAP8's start may be near
  // the end of its line, so test from the 32B wrap base rather than treating its
  // cyclic order as a linear +32 range.
  ar_4k:     assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> (rwrap_q
                          ? ((13'({m_axi_araddr[11:5], 5'd0}) +
                              13'(rbeats_q << rsize_q)) <= 13'h1000)
                          : ((13'(m_axi_araddr[11:0]) +
                              13'(rbeats_q << rsize_q)) <= 13'h1000)));
  // No AR while a posted write is buffered, being driven, or awaiting B.  This is
  // the P54C rule that cache-miss reads cannot bypass earlier write buffers.
  no_rw_overlap: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      !(m_axi_arvalid && wr_busy));
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  quad_aw_shape: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_awvalid && wr_fused_q) |->
      (m_axi_awlen == 8'd1 && m_axi_awsize == 3'd2 &&
       m_axi_awburst == 2'b01 && m_axi_awaddr[2:0] == 3'd0));
  quad_w_shape: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_wvalid && wr_fused_q) |-> (m_axi_wlast == wbeat && m_axi_wstrb == 4'hf));
  quad_credit: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      wr_quad_enq |-> ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release));
`endif
  // P2b: a store straddling a 32-bit word is now SPLIT into beat A (word) + beat B
  // (word+4). A 4-byte store shifted by at most 3 bytes touches at most 8 lanes, so it
  // can never spill past beat B — guard that the strobe is exhausted by two words.
  no_3word_wr: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (wst==W_IDLE && m_req && m_we) |-> ((({4'd0, m_wstrb} << m_addr[1:0]) >> 8) == 8'd0));
  // RLAST must land exactly on the last beat (catches a slave's early/late RLAST —
  // the beat counter now ignores RLAST for the FSM exit, this SVA flags the abuse).
  // REVIEW_Aug3 C-01: "the last beat" is rbeats_q-1 (1/2 for a narrow burst, 7 for a
  // fill), not the constant LINE_BEATS-1 — same fix as the R_DATA compare above.
  rlast_align: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_DATA && m_axi_rvalid && m_axi_rready && m_axi_rlast)
      |-> (r_beat == 8'(rbeats_q - 9'd1)));
  // every consumed response is OKAY (a SLVERR/DECERR would silently corrupt a line /
  // a store — sticky-flagged in rresp_err/bresp_err; an error pin to the core is a
  // documented follow-up, see fpga/L1_AXI_DESIGN.md).  The two focused status-fault
  // regressions deliberately violate this environmental condition, but retain every
  // other assertion under VEN_AXI_RESP_FAULT_INJECT.
`ifndef VEN_AXI_RESP_FAULT_INJECT
  rresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_DATA && m_axi_rvalid && m_axi_rready) |-> (m_axi_rresp == 2'b00));
`endif
`ifndef VEN_AXI_FAULT_INJECT
  // This master owns one fixed AXI ID.  Wrong-ID responses are terminal fabric
  // containment faults.  They may be physically drained, but must never advance
  // a fill or release a write-buffer slot.  The focused fault-injection TB
  // deliberately violates these environment assumptions, but keeps all other
  // protocol assertions enabled under VEN_AXI_FAULT_INJECT.
  rid_matches: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_rvalid |-> (m_axi_rid == AXI_ID));
  rresp_owned: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_rvalid && !rid_err) |-> ((rst == R_DATA) || (rst == R_DRAIN)));
`endif
  // The architectural/L1-facing acknowledgement is sampled on this same edge,
  // not one clock after the sticky response flags update.  A malformed response
  // may be drained for AXI protocol recovery, but it must never be delivered as
  // backing data.  The focused fault-injection gates suppress only their
  // deliberately violated ID/ownership or response-status assumptions; this
  // containment invariant remains active in every assertion build.
  no_bad_r_delivery: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      r_bad_now |-> !m_ack);
  no_fatal_delivery: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      fatal_latched |-> !m_ack);
`ifdef VEN_P54_DUAL_STORE_PAIR
  pair_atomic_ack: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_pair_ack |-> (m_ack && m_req && m_we && m_pair_req));
  pair_no_fatal_delivery: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      fatal_now |-> !m_pair_ack);
`endif
`ifndef VEN_AXI_RESP_FAULT_INJECT
  bresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      b_retire_hs |-> (m_axi_bresp == 2'b00));
`endif
`ifndef VEN_AXI_FAULT_INJECT
  bid_matches: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_bvalid |-> (m_axi_bid == AXI_ID));
`endif
`ifndef VEN_AXI_B_ORPHAN_INJECT
  // The matching-ID orphan-B containment TB is the sole assertion build that
  // intentionally violates this environment contract.  Keep it active for the
  // ordinary wrong-ID fault test: a foreign BID presented while a real command
  // is outstanding must still prove that the response phase existed.
  bresp_present_owned: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_bvalid && !bid_err) |-> (b_outstanding != B_CNTW'(0)));
`endif
  // BREADY is asserted only for a response owned by one of the two retained P54C
  // slots.  This catches any future accounting change that would acknowledge an
  // orphan B (and silently release/underflow the wrong queue entry).
  bresp_owned: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      b_retire_hs |-> b_owner_valid);
`ifndef VEN_AXI_FAULT_INJECT
`ifndef VEN_AXI_RESP_FAULT_INJECT
  no_resp_err: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (!rresp_err && !rid_err && !bresp_err && !bid_err));
`endif
`endif
  // every access fits the remap window — but ONLY when no aliasing is configured
  // (~ADDR_MASK==0). Under the KV260 4 GiB-top alias (ADDR_MASK=0x0FFF_FFFF) the high
  // bits ARE intentionally folded by remap() (SeaBIOS POSTs from 0xFFFFxxxx -> the
  // staged carveout copy), so the window check would be a FALSE positive; gate it off.
  araddr_window: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_IDLE && m_req && !m_we && (~ADDR_MASK == 32'd0))
      |-> ((m_addr & ~ADDR_MASK) == 32'd0));
  awaddr_window: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (wr_enq && (~ADDR_MASK == 32'd0))
      |-> ((m_addr & ~ADDR_MASK) == 32'd0));
`endif

  // axi_clk/axi_rst_n are tied to the core domain in the CDC_BYPASS build.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, axi_clk, axi_rst_n};
  // verilator lint_on UNUSED

`ifndef SYNTHESIS
`ifdef VEN_AXI_ADMISSION_PERF
  final begin
    $display("[AXI_ADMIT_PERF] candidate=%0d admitted=%0d rproto=%0d shutdown=%0d hold=%0d alias=%0d fatal=%0d wr_busy=%0d",
             perf_rd_candidate, perf_rd_admitted, perf_rd_block_rproto,
             perf_rd_block_shutdown, perf_rd_block_hold, perf_rd_block_alias,
             perf_rd_block_fatal, perf_rd_block_write);
  end
`endif
`endif

endmodule : ven_axi_master
