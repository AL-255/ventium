`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_axi_master.sv — ven_l1d backing port -> AXI4 master (P1-1 step 2).
//
// ven_l1d's backing port (m_*) is WORD-granular: on a line fill it holds m_req
// and walks 8 sequential, line-aligned word addresses, one m_ack per word
// (ven_l1d.sv:99,151,158 — fw advances on EVERY posedge where m_ack==1, with NO
// per-beat valid and NO backpressure); on a write-through it presents one word
// with byte strobes. This module converts that word stream into AXI4 transactions
// to the PS DDR (S_AXI_HPC0_FPD):
//   * READ  (m_we=0): ven_l1d only ever reads during a FILL, and a fill is ALWAYS
//     a full 32-byte line (8 words, base-aligned, ascending) — so a backing read is
//     COALESCED into ONE AXI INCR burst of LINE_BEATS beats (ARLEN=7). Each
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
// REMAP_BASE must be 32-byte aligned so an INCR8 burst never crosses a 4KiB page.
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
  assign alias_ssh  = {4'd0, m_wstrb} << m_addr[1:0];
  assign alias_two  = m_we ? (alias_ssh[7:4] != 4'd0)
                    : m_rd_narrow ? 1'b0
                    : (m_addr[1:0] != 2'b00);
  assign alias_last = (m_rd_narrow && !m_we)
                    ? (m_addr + ((32'd1 << m_rd_size) - 32'd1))
                    : {m_addr[31:2], 2'b00} + (alias_two ? 32'd7 : 32'd3);
  assign alias_bad = m_req && !(m_addr >= 32'hFFFE_0000)
                           && ( ((m_addr     & ~ADDR_MASK) != 32'd0)
                             || ((alias_last & ~ADDR_MASK) != 32'd0) );
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) alias_err <= 1'b0;
    else if (alias_bad) begin
      alias_err <= 1'b1;
`ifndef SYNTHESIS
      $display("[AXI] M-07 ALIAS: addr=%08h has bits outside ADDR_MASK=%08h -- would fold onto %08h, which belongs to a different physical address. Raising bus_err.",
               m_addr, ADDR_MASK, (m_addr & ADDR_MASK));
`endif
    end
  end

  // ---- READ FSM (coalesced INCR line fill) ----------------------------------
  // REVIEW2 M-08: R_DRAIN deterministically resynchronises the R channel after an
  // RLAST/beat-count mismatch (see the R_DATA arm).
  typedef enum logic [1:0] { R_IDLE, R_AR, R_DATA, R_DRAIN } rstate_e;
  rstate_e          rst;
  logic [ADDR_W-1:0] araddr_q;     // line-aligned burst base (registered, stable)
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
  logic              wd_err_r;     // sticky: a READ watchdog timeout aborted (read-FF driven)
  logic              wd_err_w;     // sticky: a WRITE watchdog timeout aborted (write-FF driven)
  logic [15:0]       r_wd, w_wd;   // #34 read/write watchdog cycle counters (since last progress)

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
  always_ff @(posedge core_clk) begin
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
  // writes before lane alignment; an active entry is one of the two slots until its
  // final AW/W transfer has been accepted.  AXI B responses may trail that transfer,
  // but reads wait for those as well (see R_IDLE below).
  localparam int unsigned P5_WBUF_DEPTH = 2;
  localparam int unsigned WBUF_PTRW = $clog2(P5_WBUF_DEPTH);
  localparam int unsigned WBUF_CNTW = $clog2(P5_WBUF_DEPTH + 1);
  localparam int unsigned B_CNTW    = $clog2((P5_WBUF_DEPTH * 2) + 1);

  typedef enum logic { W_IDLE, W_RUN } wstate_e;
  wstate_e          wst;
  logic [31:0]       wq_addr [P5_WBUF_DEPTH];
  logic [31:0]       wq_wdata[P5_WBUF_DEPTH];
  logic [3:0]        wq_wstrb[P5_WBUF_DEPTH];
  logic [WBUF_PTRW-1:0] wq_rp, wq_wp;
  logic [WBUF_CNTW-1:0] wq_count;
  logic                 wr_enq, wr_dispatch, wr_busy;
  logic [63:0]          q_dsh;
  logic [7:0]           q_ssh;
  logic                 wr_active;
  logic [B_CNTW-1:0]    b_outstanding;
  logic                 aw_hs, w_hs, b_hs, wr_beat_sent, wr_progress;

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

  // A write admission is the CPU-facing completion point.  Keep the full, active
  // entry in the accounting so there are never more than two P54C write-buffer
  // entries awaiting an AW/W transfer.  Once AXI accepts a beat it is externally
  // owned; B remains in b_outstanding solely for ordering/error/quiesce purposes.
  always_comb begin
    q_dsh = {32'd0, wq_wdata[wq_rp]} << {wq_addr[wq_rp][1:0], 3'b000};
    q_ssh = {4'd0,  wq_wstrb[wq_rp]} << wq_addr[wq_rp][1:0];
  end
  assign wr_enq      = (rst == R_IDLE) && m_req && m_we && !shutdown && !alias_bad &&
                       ((wq_count + (wr_active ? WBUF_CNTW'(1) : WBUF_CNTW'(0))) < WBUF_CNTW'(P5_WBUF_DEPTH));
  assign wr_dispatch = !wr_active && (wq_count != WBUF_CNTW'(0));
  assign wr_busy     = wr_active || (wq_count != WBUF_CNTW'(0)) ||
                       (b_outstanding != B_CNTW'(0));
  assign wst         = wr_busy ? W_RUN : W_IDLE;

  // ---- AXI combinational drive ----------------------------------------------
  always_comb begin
    // read address channel — burst base forced 32B-aligned (never crosses 4KiB).
    m_axi_arid    = AXI_ID;
    m_axi_araddr  = araddr_q;
    m_axi_arlen   = 8'(rbeats_q - 9'd1);  // H-11: latched length (LINE_BEATS, or 1 narrow)
    // R2-H01: exact ARSIZE for narrow device pieces (1B/2B/4B); fills are 4B.
    m_axi_arsize  = {1'b0, rsize_q};      // AXI encoding matches rsize_q 0/1/2
    m_axi_arburst = 2'b01;               // INCR
    m_axi_arlock  = 1'b0;
    m_axi_arcache = 4'b0011;             // Normal NON-cacheable bufferable: the BD uses NON-coherent
                                         // HP0, and cacheable attrs legally let the SmartConnect width
                                         // converter serve reads from PREVIOUSLY FETCHED data — the
                                         // stale-read source (PS-written DDR invisible to the guest).
    m_axi_arprot  = 3'b000;
    m_axi_arqos   = 4'd0;
    m_axi_arvalid = (rst == R_AR);
    // M-08: RREADY is also asserted while DRAINING -- the whole point of the drain is
    // to consume the beats a late-RLAST slave still owes, so the next transaction does
    // not inherit them.
    m_axi_rready  = (rst == R_DATA) || (rst == R_DRAIN);

    // write address channel — one aligned 4-byte beat from the active P5 buffer.
    m_axi_awid    = AXI_ID;
    m_axi_awaddr  = awaddr_q;
    m_axi_awlen   = 8'd0;
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
    m_axi_wlast   = 1'b1;                 // single-beat write
    m_axi_wvalid  = wr_active && !w_done;
    // write response channel
    m_axi_bready  = (b_outstanding != B_CNTW'(0));

    // backing response: a read beat hands RDATA back as one m_ack; the write acks on
    // BVALID. On a watchdog timeout the AXI handshake is HELD (a master cannot retract
    // VALID — AXI has no cancel), bus_err is raised, and the core's bus_err->S_HALT
    // override abandons the stuck access + halts (the PS then resets). No protocol-
    // violating abort, no drain.
    // clean-shutdown quiesce: both FSMs idle == no outstanding AXI (every *VALID is
    // gated on a non-IDLE state above, so IDLE is the protocol-safe drained state).
    m_idle  = (rst == R_IDLE) && (wst == W_IDLE);
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
    m_ack   = ((rst == R_DATA) && m_axi_rvalid && m_axi_rready && rd_primed) ||   // deliver ONLY the real burst
                                                                                  // (a fill's 2nd; a narrow read's 1st/only — C-01)
              wr_enq ||
              (shutdown && m_idle && m_req);          // shutdown: local ack, no DDR
    bus_err = wd_err_r | wd_err_w | rresp_err | bresp_err | rlast_err | alias_err; // #34 + M-08 + M-07
  end

  assign aw_hs       = m_axi_awvalid && m_axi_awready;
  assign w_hs        = m_axi_wvalid  && m_axi_wready;
  assign b_hs        = m_axi_bvalid  && m_axi_bready;
  assign wr_beat_sent = wr_active && (aw_done || aw_hs) && (w_done || w_hs);
  assign wr_progress = wr_enq || wr_dispatch || aw_hs || w_hs || b_hs;

`ifdef VEN_DBG_CORE
  // read-beat trace taps: capture the address + data of every ACCEPTED read beat.
  assign dbg_rd_valid = (rst == R_DATA) && m_axi_rvalid && m_axi_rready && rd_primed;  // real burst only
  assign dbg_rd_addr  = araddr_q[31:0] + {22'd0, r_beat, 2'b00};
  assign dbg_rd_data  = m_axi_rdata;
`endif

  // ---- READ sequencing -------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      rst <= R_IDLE; araddr_q <= '0; r_beat <= 8'd0; rresp_err <= 1'b0; rlast_err <= 1'b0;
      rbeats_q <= 9'(LINE_BEATS); rsize_q <= 2'd2; narrow_q <= 1'b0;
      r_wd <= 16'd0; wd_err_r <= 1'b0; rd_primed <= 1'b0;
    end else begin
      unique case (rst)
        // REVIEW_aug2 H-07: an ALIASING request must be REJECTED, not merely recorded.
        // alias_err was sticky and fed bus_err, but neither FSM start tested it -- the
        // same clock that recorded the error latched the remapped address, so a write
        // went out through AW/W/B and could corrupt the aliased LOW DDR location before
        // the delayed bus_err halted the core. That is detection, not rejection.
        // Gating the start means no AXI transaction is ever launched for an out-of-
        // window address; bus_err still halts the core, exactly as the #34 watchdog does.
        R_IDLE: if (m_req && !m_we && !shutdown && !rd_hold && !alias_bad && !wr_busy) begin
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
                  end else begin
                    araddr_q <= remap({m_addr[31:5], 5'd0});
                    rbeats_q <= 9'(LINE_BEATS);
                    rsize_q  <= 2'd2;               // fills are always 4B beats
                    narrow_q <= 1'b0;
                  end
                  r_beat <= 8'd0; rresp_err <= 1'b0; r_wd <= 16'd0;
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
                  rd_primed <= m_rd_narrow && !NARROW_REPLAY_SAFE;
`endif
                  rst <= R_AR;
                end
        R_AR:   if (m_axi_arready) begin rst <= R_DATA; r_wd <= 16'd0; end // AR accepted
                // #34 watchdog: a stall of WATCHDOG cycles with no progress -> raise
                // the sticky fault (bus_err) but HOLD arvalid (AXI: VALID can't retract).
                else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;
                else r_wd <= r_wd + 16'd1;
        R_DATA: if (m_axi_rvalid && m_axi_rready) begin       // beat accepted (progress)
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
                  if (m_axi_rlast != (r_beat == 8'(rbeats_q - 9'd1))) rlast_err <= 1'b1;
                  if (m_axi_rlast && (r_beat != 8'(rbeats_q - 9'd1))) begin
                    // EARLY RLAST: the slave has ENDED the burst, so the beats this
                    // master is still counting will never arrive. Previously the FSM
                    // sat here until the #34 watchdog fired -- a timeout, not a defined
                    // recovery. Terminate now; bus_err is already sticky, so the core
                    // halts on a known cycle instead of an arbitrary one.
                    r_beat <= 8'd0; rst <= R_IDLE;
                  end else if (r_beat == 8'(rbeats_q - 9'd1)) begin
                    if (!m_axi_rlast) begin
                      // LATE RLAST: our count is satisfied but the slave still owes
                      // beats. Returning to IDLE here would let the NEXT AR be issued
                      // while those beats are in flight, and they would be consumed as
                      // the new burst's data -- silent cross-transaction corruption.
                      // Drain to the real RLAST first.
                      rst <= R_DRAIN;
                    end else if (!rd_primed) begin
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
        R_DRAIN: if (m_axi_rvalid && m_axi_rready) begin
                   if (m_axi_rlast) begin r_beat <= 8'd0; rst <= R_IDLE; end
                   r_wd <= 16'd0;
                 end
                 else if (r_wd >= 16'(WATCHDOG)) wd_err_r <= 1'b1;
                 else r_wd <= r_wd + 16'd1;
        default: rst <= R_IDLE;
      endcase
    end
  end

  // ---- WRITE-buffer sequencing ----------------------------------------------
  // CPU-facing enqueue, FIFO dispatch, AXI transfer, and B response retirement
  // are deliberately separate.  In particular, dequeuing an entry after AW/W is
  // accepted does NOT let a read bypass it: b_outstanding remains part of wr_busy
  // until the ordered B response has arrived.
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      wq_rp <= '0; wq_wp <= '0; wq_count <= '0;
      for (int i = 0; i < P5_WBUF_DEPTH; i++) begin
        wq_addr[i] <= '0; wq_wdata[i] <= '0; wq_wstrb[i] <= '0;
      end
      wr_active <= 1'b0;
      awaddr_q <= '0; wdata_q <= 32'd0; wstrb_q <= 4'd0;
      awaddr2_q <= '0; wdata2_q <= 32'd0; wstrb2_q <= 4'd0;
      xword_q <= 1'b0; wbeat <= 1'b0; aw_done <= 1'b0; w_done <= 1'b0;
      b_outstanding <= '0;
      bresp_err <= 1'b0; w_wd <= 16'd0; wd_err_w <= 1'b0;
    end else begin
      // FIFO accounting permits an enqueue and a dispatch on the same edge.  The
      // active entry is counted separately by wr_enq's capacity predicate, so this
      // never turns the two P54C buffers into a three-entry queue.
      unique case ({wr_enq, wr_dispatch})
        2'b10: wq_count <= wq_count + WBUF_CNTW'(1);
        2'b01: wq_count <= wq_count - WBUF_CNTW'(1);
        default: ;
      endcase
      if (wr_enq) begin
        wq_addr[wq_wp]  <= m_addr;
        wq_wdata[wq_wp] <= m_wdata;
        wq_wstrb[wq_wp] <= m_wstrb;
        wq_wp <= wq_wp + WBUF_PTRW'(1);
      end
      if (wr_dispatch) begin
        // BYTE-LANE ALIGN (P2 fix): the core's byte zero is shifted onto the
        // matching AXI word lane.  An unaligned 16/32-bit store can spill into
        // exactly one following word; both beats remain adjacent in FIFO order.
        awaddr_q  <= remap({wq_addr[wq_rp][31:2], 2'b00});
        wdata_q   <= q_dsh[31:0];
        wstrb_q   <= q_ssh[3:0];
        awaddr2_q <= remap({wq_addr[wq_rp][31:2], 2'b00} + 32'd4);
        wdata2_q  <= q_dsh[63:32];
        wstrb2_q  <= q_ssh[7:4];
        xword_q   <= (q_ssh[7:4] != 4'd0);
        wbeat     <= 1'b0;
        aw_done   <= 1'b0;
        w_done    <= 1'b0;
        wr_active <= 1'b1;
        wq_rp     <= wq_rp + WBUF_PTRW'(1);
      end

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
            awaddr_q <= awaddr2_q;
            wdata_q  <= wdata2_q;
            wstrb_q  <= wstrb2_q;
            wbeat    <= 1'b1;
            aw_done  <= 1'b0;
            w_done   <= 1'b0;
          end else begin
            wr_active <= 1'b0;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
          end
        end
      end

      // AXI4 orders B responses for one ID.  They are retired in that same order,
      // and any failure stays sticky even if later requests are still draining.
      if (b_hs && m_axi_bresp != 2'b00) bresp_err <= 1'b1;
      unique case ({wr_beat_sent, b_hs})
        2'b10: b_outstanding <= b_outstanding + B_CNTW'(1);
        2'b01: b_outstanding <= b_outstanding - B_CNTW'(1);
        default: ;
      endcase

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
                                             && $stable(m_axi_arlen)));
  aw_stable: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_awvalid && !m_axi_awready) |=> (m_axi_awvalid && $stable(m_axi_awaddr)));
  // W payload stable independent of AW (decoupling check).
  w_stable:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (m_axi_wvalid && !m_axi_wready) |=> (m_axi_wvalid && $stable(m_axi_wdata)
                                           && $stable(m_axi_wstrb) && $stable(m_axi_wlast)));
  // burst-base alignment, by burst SHAPE (REVIEW_Aug3 C-01): a line fill
  // (rbeats_q == LINE_BEATS) is 32B-aligned; a narrow piece is exactly
  // SIZE-aligned to its own ARSIZE (REVIEW1_Aug3 R2-H01) — its whole point is to
  // address the requested bytes, not a line or even a word base.
  ar_align:  assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> (narrow_q
                         ? ((m_axi_araddr[1:0] & (2'b11 >> (2'd2 - rsize_q))) == 2'd0)
                         : (m_axi_araddr[4:0] == 5'd0)));
`ifndef SYNTHESIS
  // debug tap (cosim bring-up): print the offending AR when ar_align fires.
  // Negedge: the fatal assert's $stop at the posedge would preempt a posedge tap.
  always @(negedge core_clk)
    if (core_rst_n && m_axi_arvalid &&
        !(narrow_q ? ((m_axi_araddr[1:0] & (2'b11 >> (2'd2 - rsize_q))) == 2'd0)
                   : (m_axi_araddr[4:0] == 5'd0)))
      $display("[ARALIGN] araddr=%h narrow=%b rsize=%0d rbeats=%0d m_addr=%h m_size=%0d m_narrow=%b",
               m_axi_araddr, narrow_q, rsize_q, rbeats_q, m_addr, m_rd_size, m_rd_narrow);
`endif
  // the burst's ACTUAL extent never crosses 4KiB: beats << ARSIZE (a fill is
  // 8*4=32; a narrow piece is 1*(1|2|4) bytes, size-aligned, so it cannot cross).
  ar_4k:     assert property (@(posedge core_clk) disable iff (!core_rst_n)
      m_axi_arvalid |-> ((13'(m_axi_araddr[11:0]) + 13'(rbeats_q << rsize_q)) <= 13'h1000));
  // No AR while a posted write is buffered, being driven, or awaiting B.  This is
  // the P54C rule that cache-miss reads cannot bypass earlier write buffers.
  no_rw_overlap: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      !(m_axi_arvalid && wr_busy));
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
  // documented follow-up, see fpga/L1_AXI_DESIGN.md).
  rresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (rst==R_DATA && m_axi_rvalid && m_axi_rready) |-> (m_axi_rresp == 2'b00));
  bresp_okay: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      b_hs |-> (m_axi_bresp == 2'b00));
  no_resp_err: assert property (@(posedge core_clk) disable iff (!core_rst_n)
      (!rresp_err && !bresp_err));
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

  // lint sinks: RID/BID not consulted (single in-flight, AxID=0); axi_clk/axi_rst_n
  // are tied to the core domain in the CDC_BYPASS build. (RRESP/BRESP ARE consulted
  // now — the sticky rresp_err/bresp_err flags + the resp SVAs above.)
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, m_axi_bid, m_axi_rid, axi_clk, axi_rst_n};
  // verilator lint_on UNUSED

endmodule : ven_axi_master
