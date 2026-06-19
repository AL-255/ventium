// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ventium_l1_axi.sv — the L1 + AXI4 memory subsystem (P1-1 step 2/3).
//
// The linchpin for booting Ventium on the KV260: it bridges the core's
// SAME-CYCLE-ACK 32-bit memory port (the dual-issue fast path latches load data
// the clock it asserts the request) to the PS DDR4 over AXI4 (multi-cycle), hiding
// DDR latency behind the L1 cache that acks on a hit in the same clock.
//
//   core mem_*  ──►  ven_l1d  ──(word backing port)──►  ven_axi_master  ──►  AXI4
//   (same-cycle      (8KB/2-way      (coalesce the 8-word         (-> S_AXI_HPC0_FPD
//    ack on hit)      32B line)       line fill into 1 INCR        -> SmartConnect
//                                     burst; write = 1 beat)       -> PS DDR)
//
// Contract presented to the core (fpga/L1_AXI_DESIGN.md §1):
//   * READ HIT  -> c_rdata valid + c_ack=1 the SAME clock (combinational off the L1
//     arrays). Mandatory: the fast path has no register stage on the load.
//   * READ MISS -> c_ack=0 (the core stalls / the fast-path miss-stall gate holds)
//     while the AXI burst fills the line; the retry then hits.
//   * WRITE     -> write-through; c_ack pulses when the AXI write is accepted (B).
//
// REMAP_BASE/ADDR_MASK place the x86 physical space into the reserved DDR window
// (ddr_addr = REMAP_BASE + (phys & ADDR_MASK)); the L1 itself is purely
// PHYSICAL-addressed (no TLB inside — the core already translated).
//
// The m_axi_* ports carry Xilinx X_INTERFACE attributes so Vivado's Module-
// Reference flow infers a single AXI4 master bundle named `m_axi` (else the BD's
// connect_bd_intf_net to S_AXI_HPC0 finds no interface pin). core_clk and axi_clk
// are separate ports; the BD ties both to pl_clk0 (single-clock bring-up, the
// CDC_BYPASS build), leaving room for a later MMCM dual-clock variant.

module ventium_l1_axi #(
    parameter int          L1_SETS    = 128,
    parameter int          L1_LINE    = 32,                // bytes/line
    parameter int          ADDR_W     = 40,                // PS8 HPC0 master addr
    parameter logic [39:0] REMAP_BASE = 40'h00_0000_0000,
    parameter logic [31:0] ADDR_MASK  = 32'hFFFF_FFFF,
    parameter logic [3:0]  AXI_ID     = 4'd0,
    parameter int unsigned WATCHDOG   = 1024,           // #34 AXI stall watchdog cycles
    // ---- Phase B (docs/northbridge-system-spec.md §5): splice the UltraRAM L2
    // (ven_l2) into the L1 backing seam — ven_l1d.m_* → ven_l2.u_*, ven_l2.d_* →
    // ven_axi_master.m_*. DEFAULT 0 = the L2 is BYPASSED (the backing port wires
    // straight through, byte-identical to the pre-L2 subsystem AND its AXI-traffic
    // pattern — so every existing L1AXI gate stays green and the board build is
    // unchanged). 1 = the L2 is IN the datapath (the integration gate run-l1l2-gate.sh
    // drives this; the board flips it in Phase E behind the northbridge). The L2 is
    // WRITE-BACK, so with EN_L2=1 the AXI traffic shape CHANGES (stores are absorbed
    // until eviction) — which is why AXI-pattern gates keep the default 0.
    parameter bit          EN_L2        = 1'b0,
    parameter int          L2_CAP_BYTES = 2*1024*1024,     // 2 MiB (= all 64 URAM288)
    parameter int          L2_WAYS      = 8,
    // ---- Phase C: ven_northbridge cacheability config (the 430FX TSC registers).
    // These are the BOOT defaults until the PCI-config shim drives them (Phase D):
    // FLCE=1 + SCS=01 (L1 + a populated L2), no memory hole, all DRAM below TOM
    // cacheable, BIOS/ROM windows (PAM) default-uncacheable (→ bypass to DDR).
    // Effective only when EN_L2=1 (the northbridge is present); EN_L2=0 keeps the L1
    // unconditionally caching (byte-identical).
    parameter logic [7:0]  NB_CC      = 8'h41,             // FLCE=1, SCS=01, SCFMI=0
    parameter logic [7:0]  NB_DRAMC   = 8'h01,             // HEN=00 (no hole)
    parameter logic [7:0]  NB_TOM_MB4 = 8'd255,            // ~1020 MiB cacheable DRAM
    parameter logic [55:0] NB_PAM     = 56'h0,             // ROM windows uncacheable by default
    parameter logic [7:0]  NB_SMRAM   = 8'h00
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 core_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET core_rst_n" *)
    input  logic        core_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 core_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic        core_rst_n,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axi, ASSOCIATED_RESET axi_rst_n" *)
    input  logic        axi_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic        axi_rst_n,

    // ---- core side (the same-cycle-ack contract; mirrors core mem_*) ----------
    input  logic        flush_all,       // #35 external L1 invalidation (clear all val)
    input  logic        golden_l1,       // golden/L1-useless diagnostic mode (flush after each access)
    input  logic        core_req,
    input  logic        core_we,
    input  logic [31:0] core_addr,
    input  logic [31:0] core_wdata,
    input  logic [3:0]  core_wstrb,
    output logic [31:0] core_rdata,
    output logic        core_ack,
    output logic        bus_err,        // #34 fatal AXI fault (watchdog timeout / SLVERR)

    // ---- clean-shutdown quiesce (pass-through to ven_axi_master) ---------------
    input  logic        shutdown,        // 1 = stop new AXI txns, drain in-flight
    output logic        m_idle,          // 1 = AXI master drained -> safe to remove overlay

`ifdef VEN_DBG_CORE
    // ---- read-beat trace (VEN_DBG_CORE): pass-through from ven_axi_master ------
    output logic        dbg_rd_valid,
    output logic [31:0] dbg_rd_addr,
    output logic [31:0] dbg_rd_data,
`endif

    // ---- AXI4 master port (-> S_AXI_HPC0_FPD), bundle `m_axi` ------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWID" *)
    output logic [3:0]        m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    output logic [ADDR_W-1:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLEN" *)
    output logic [7:0]        m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWSIZE" *)
    output logic [2:0]        m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWBURST" *)
    output logic [1:0]        m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWLOCK" *)
    output logic              m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWCACHE" *)
    output logic [3:0]        m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWPROT" *)
    output logic [2:0]        m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWQOS" *)
    output logic [3:0]        m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWVALID" *)
    output logic              m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWREADY" *)
    input  logic              m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WDATA" *)
    output logic [31:0]       m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WSTRB" *)
    output logic [3:0]        m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WLAST" *)
    output logic              m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WVALID" *)
    output logic              m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi WREADY" *)
    input  logic              m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BID" *)
    input  logic [3:0]        m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BRESP" *)
    input  logic [1:0]        m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BVALID" *)
    input  logic              m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi BREADY" *)
    output logic              m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARID" *)
    output logic [3:0]        m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARADDR" *)
    output logic [ADDR_W-1:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLEN" *)
    output logic [7:0]        m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARSIZE" *)
    output logic [2:0]        m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARBURST" *)
    output logic [1:0]        m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARLOCK" *)
    output logic              m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARCACHE" *)
    output logic [3:0]        m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARPROT" *)
    output logic [2:0]        m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARQOS" *)
    output logic [3:0]        m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARVALID" *)
    output logic              m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi ARREADY" *)
    input  logic              m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RID" *)
    input  logic [3:0]        m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RDATA" *)
    input  logic [31:0]       m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RRESP" *)
    input  logic [1:0]        m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RLAST" *)
    input  logic              m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RVALID" *)
    input  logic              m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi RREADY" *)
    output logic              m_axi_rready
`ifdef VEN_DBG_L2
    // ---- L2 observability (opt-in, gate-only define — NOT seen by ventium_top, so
    // no plumbing churn there). Surfaces ven_l2's perf counters + init-ready so the
    // integration gate (and future validation) can read L2 hit/miss/writeback rate.
    // The counters themselves need VEN_DBG_CORE in ven_l2; without it they read 0.
    ,
    output logic        dbg_l2_ready,
    output logic [31:0] dbg_l2_hits,
    output logic [31:0] dbg_l2_misses,
    output logic [31:0] dbg_l2_wbacks,
    output logic [31:0] dbg_l2_bypass
`endif
);

  // ---- internal word-granular backing port (L1 <-> AXI master) --------------
  // ven_l1d's backing master (always in core_clk). In the default single-clock
  // build these wire STRAIGHT to ven_axi_master; in +VEN_AXI_CDC they cross to the
  // axi_clk domain through ven_axi_cdc first (see below).
  logic        m_req, m_we;
  logic [31:0] m_addr, m_wdata;
  logic [3:0]  m_wstrb;
  logic [31:0] m_rdata;
  logic        m_ack;

  // ---- post-L2 backing port (b_*): the seam between the L2 (or the bypass) and the
  // AXI master / CDC. With EN_L2=0 these are wired straight to m_* (transparent);
  // with EN_L2=1 ven_l2 sits between m_* (its upstream u_*) and b_* (its downstream d_*).
  logic        b_req, b_we;
  logic [31:0] b_addr, b_wdata;
  logic [3:0]  b_wstrb;
  logic [31:0] b_rdata;
  logic        b_ack;
  logic        l2_ready;          // 1 once the L2 finishes its post-reset valid-clear walk
  // observability wires (driven by ven_l2/ven_northbridge under VEN_DBG_CORE; 0 otherwise).
  logic [31:0] l2_hits_w, l2_misses_w, l2_wbacks_w, l2_bypass_w;
  // KEN# for the L1 D-cache: with the northbridge present (EN_L2), a cachemap on the
  // CORE address decides cacheability so MMIO is never L1-cached; else cache everything.
  // Driven inside the EN_L2 generate (below) so EN_L2=0 builds don't pull in ven_cachemap.
  logic l1d_cacheable;

  // ven_axi_master's backing slave + its clock/reset — a COMPILE-TIME (ifdef) alias
  // of either the core domain (default) or the axi domain (+VEN_AXI_CDC). Static
  // selection: exactly one `assign` exists per build, so axm_clk is a direct net
  // alias (no runtime clock mux / gated clock), and ven_axi_master stays UNTOUCHED
  // (it is single-clock on whichever clock it is handed).
  logic        axm_clk, axm_rst_n;
  logic        axm_req, axm_we;
  logic [31:0] axm_addr, axm_wdata;
  logic [3:0]  axm_wstrb;
  logic [31:0] axm_rdata;
  logic        axm_ack, axm_bus_err;

  // l1d uses a domain-synchronized reset in the CDC build, the raw reset otherwise.
  logic        l1d_rst_n;

`ifdef VEN_AXI_CDC
  // ---- dual-clock: synchronize each domain's reset, then bridge the backing port.
  // #36 RESET COUPLING (review HIGH): a reset in EITHER domain must reset BOTH. An
  // asymmetric reset mid-transaction (e.g. an AXI soft-reset / MMCM lock loss drops
  // ONLY axi_rst_n) would wipe the producer state of an in-flight transaction: the
  // command was already popped, so no response is ever pushed, ven_l1d hangs in its
  // fill forever, AND the #34 watchdog (living in the just-reset axi domain) cannot
  // fire -> an undetectable deadlock. AND the raw resets so the UNION of reset events
  // async-asserts both per-domain synchronizers together (glitch-safe for a level
  // async-assert; each domain still sync-DEASSERTS cleanly in its own clock, and on
  // deassertion the FIFOs/FSMs are idle so the sync-latency skew is benign).
  logic rst_comb_n;
  assign rst_comb_n = core_rst_n & axi_rst_n;
  logic core_rst_sync_n, axi_rst_sync_n;
  ven_reset_sync u_rs_core (.clk(core_clk), .arst_n(rst_comb_n), .srst_n(core_rst_sync_n));
  ven_reset_sync u_rs_axi  (.clk(axi_clk),  .arst_n(rst_comb_n), .srst_n(axi_rst_sync_n));
  assign l1d_rst_n = core_rst_sync_n;
  assign axm_clk   = axi_clk;
  assign axm_rst_n = axi_rst_sync_n;

  ven_axi_cdc #(.LINE_BEATS(L1_LINE/4)) u_cdc (
      .core_clk   (core_clk),        .core_rst_n (core_rst_sync_n),
      .axi_clk    (axi_clk),         .axi_rst_n  (axi_rst_sync_n),
      // core side: the post-L2 backing master (b_*; == m_* when EN_L2=0)
      .c_req      (b_req),  .c_we    (b_we),    .c_addr  (b_addr),
      .c_wdata    (b_wdata),.c_wstrb (b_wstrb), .c_rdata (b_rdata),
      .c_ack      (b_ack),  .bus_err (bus_err),
      // axi side: drives ven_axi_master's backing slave
      .a_req      (axm_req),  .a_we    (axm_we),    .a_addr  (axm_addr),
      .a_wdata    (axm_wdata),.a_wstrb (axm_wstrb), .a_rdata (axm_rdata),
      .a_ack      (axm_ack),  .a_bus_err(axm_bus_err)
  );
`else
  // ---- default single-clock (CDC_BYPASS): wire the post-L2 backing straight through.
  assign l1d_rst_n = core_rst_n;
  assign axm_clk   = core_clk;
  assign axm_rst_n = core_rst_n;
  assign axm_req   = b_req;   assign axm_we    = b_we;
  assign axm_addr  = b_addr;  assign axm_wdata = b_wdata;  assign axm_wstrb = b_wstrb;
  assign b_rdata   = axm_rdata; assign b_ack   = axm_ack;  assign bus_err   = axm_bus_err;
`endif

  // ---- L2 splice (Phase B): EN_L2=0 → transparent (b_* = m_*); EN_L2=1 → ven_l2
  // sits between the L1's backing master (m_*) and the AXI/CDC path (b_*). ven_l2 is
  // a proven drop-in for this exact word-granular backing protocol on both ports
  // (verif/l1/run-l2-axi-gate.sh ran it end-to-end through the real ven_axi_master).
  generate
    if (EN_L2) begin : g_l2
      // KEN# for the L1 D-cache (data path; is_code=0) — MMIO is never L1-cached.
      logic core_l1c, core_to_dram_u, core_l2c_u; logic [3:0] core_cm_region;
      ven_cachemap u_cmap_l1 (
          .addr(core_addr), .is_write(core_we), .is_code(1'b0), .smm_active(1'b0),
          .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
          .to_dram(core_to_dram_u), .l1_cacheable(core_l1c), .l2_cacheable(core_l2c_u),
          .region(core_cm_region));
      assign l1d_cacheable = core_l1c;
      // Phase C: the northbridge (cachemap + L2 + uncacheable bypass) sits in the seam.
      ven_northbridge #(.L2_CAP_BYTES(L2_CAP_BYTES), .L2_LINE(L1_LINE), .L2_WAYS(L2_WAYS)) u_nb (
          .clk   (core_clk),
          .rst_n (l1d_rst_n),       // L2's own reset (NOT gated on its own ready)
          .ready (l2_ready),
          .cfg_pam(NB_PAM), .cfg_dramc(NB_DRAMC), .cfg_cc(NB_CC),
          .cfg_tom_mb4(NB_TOM_MB4), .cfg_smram(NB_SMRAM), .smm_active(1'b0),
          // upstream slave ⇐ the L1's backing master
          .u_req (m_req),  .u_we (m_we),  .u_addr (m_addr), .u_wdata (m_wdata),
          .u_wstrb(m_wstrb), .u_rdata(m_rdata), .u_ack (m_ack),
          // downstream master ⇒ the AXI master / CDC backing slave
          .d_req (b_req),  .d_we (b_we),  .d_addr (b_addr), .d_wdata (b_wdata),
          .d_wstrb(b_wstrb), .d_rdata(b_rdata), .d_ack (b_ack)
`ifdef VEN_DBG_CORE
          , .dbg_hits(l2_hits_w), .dbg_misses(l2_misses_w), .dbg_wbacks(l2_wbacks_w),
            .dbg_bypass(l2_bypass_w)
`endif
      );
    end else begin : g_nol2
      // L2 bypassed: the backing port is transparent (byte-identical to pre-L2).
      assign b_req = m_req;   assign b_we = m_we;   assign b_addr = m_addr;
      assign b_wdata = m_wdata; assign b_wstrb = m_wstrb;
      assign m_rdata = b_rdata; assign m_ack = b_ack;
      assign l2_ready = 1'b1;
      assign l1d_cacheable = 1'b1;       // cache everything (byte-identical to pre-L2)
    end
  endgenerate
  // Pin the observability wires to 0 wherever the generate does NOT drive them (the
  // g_l2 branch drives them only when EN_L2=1 AND VEN_DBG_CORE) — exactly one driver.
`ifdef VEN_DBG_CORE
  if (!EN_L2) begin : g_dbg0
    assign l2_hits_w = 32'd0; assign l2_misses_w = 32'd0;
    assign l2_wbacks_w = 32'd0; assign l2_bypass_w = 32'd0;
  end
`else
  assign l2_hits_w = 32'd0; assign l2_misses_w = 32'd0;
  assign l2_wbacks_w = 32'd0; assign l2_bypass_w = 32'd0;
`endif
`ifdef VEN_DBG_L2
  assign dbg_l2_ready  = l2_ready;
  assign dbg_l2_hits   = l2_hits_w;
  assign dbg_l2_misses = l2_misses_w;
  assign dbg_l2_wbacks = l2_wbacks_w;
  assign dbg_l2_bypass = l2_bypass_w;
`endif

  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (
      .clk      (core_clk),
      // hold the L1 (and thus the core, which stalls on c_ack) in reset until the L2
      // has finished its post-reset valid-clear walk (l2_ready). EN_L2=0 → l2_ready=1
      // → this is exactly l1d_rst_n (byte-identical).
      .rst_n    (l1d_rst_n & l2_ready),
      .flush_all(flush_all),
      .golden   (golden_l1),
      // Phase C: KEN# from the cachemap (EN_L2) so MMIO is never L1-cached; EN_L2=0 →
      // 1'b1 (byte-identical). Snoop still inert until DMA coherence (Phase D).
      .cacheable      (l1d_cacheable),
      .snoop_inv_valid(1'b0),
      .snoop_inv_addr (32'd0),
      .c_req   (core_req),
      .c_we    (core_we),
      .c_addr  (core_addr),
      .c_wdata (core_wdata),
      .c_wstrb (core_wstrb),
      .c_rdata (core_rdata),
      .c_ack   (core_ack),
      .m_req   (m_req),
      .m_we    (m_we),
      .m_addr  (m_addr),
      .m_wdata (m_wdata),
      .m_wstrb (m_wstrb),
      .m_rdata (m_rdata),
      .m_ack   (m_ack)
  );

  ven_axi_master #(
      .LINE_BEATS (L1_LINE/4),
      .ADDR_W     (ADDR_W),
      .REMAP_BASE (REMAP_BASE),
      .ADDR_MASK  (ADDR_MASK),
      .AXI_ID     (AXI_ID),
      .WATCHDOG   (WATCHDOG)
  ) u_axi (
      .core_clk    (axm_clk),
      .core_rst_n  (axm_rst_n),
      .axi_clk     (axi_clk),
      .axi_rst_n   (axi_rst_n),
      .m_req       (axm_req),
      .m_we        (axm_we),
      .m_addr      (axm_addr),
      .m_wdata     (axm_wdata),
      .m_wstrb     (axm_wstrb),
      .m_rdata     (axm_rdata),
      .m_ack       (axm_ack),
      .bus_err     (axm_bus_err),
      .shutdown    (shutdown),
      .m_idle      (m_idle),
`ifdef VEN_DBG_CORE
      .dbg_rd_valid (dbg_rd_valid),
      .dbg_rd_addr  (dbg_rd_addr),
      .dbg_rd_data  (dbg_rd_data),
`endif
      .m_axi_awid    (m_axi_awid),
      .m_axi_awaddr  (m_axi_awaddr),
      .m_axi_awlen   (m_axi_awlen),
      .m_axi_awsize  (m_axi_awsize),
      .m_axi_awburst (m_axi_awburst),
      .m_axi_awlock  (m_axi_awlock),
      .m_axi_awcache (m_axi_awcache),
      .m_axi_awprot  (m_axi_awprot),
      .m_axi_awqos   (m_axi_awqos),
      .m_axi_awvalid (m_axi_awvalid),
      .m_axi_awready (m_axi_awready),
      .m_axi_wdata   (m_axi_wdata),
      .m_axi_wstrb   (m_axi_wstrb),
      .m_axi_wlast   (m_axi_wlast),
      .m_axi_wvalid  (m_axi_wvalid),
      .m_axi_wready  (m_axi_wready),
      .m_axi_bid     (m_axi_bid),
      .m_axi_bresp   (m_axi_bresp),
      .m_axi_bvalid  (m_axi_bvalid),
      .m_axi_bready  (m_axi_bready),
      .m_axi_arid    (m_axi_arid),
      .m_axi_araddr  (m_axi_araddr),
      .m_axi_arlen   (m_axi_arlen),
      .m_axi_arsize  (m_axi_arsize),
      .m_axi_arburst (m_axi_arburst),
      .m_axi_arlock  (m_axi_arlock),
      .m_axi_arcache (m_axi_arcache),
      .m_axi_arprot  (m_axi_arprot),
      .m_axi_arqos   (m_axi_arqos),
      .m_axi_arvalid (m_axi_arvalid),
      .m_axi_arready (m_axi_arready),
      .m_axi_rid     (m_axi_rid),
      .m_axi_rdata   (m_axi_rdata),
      .m_axi_rresp   (m_axi_rresp),
      .m_axi_rlast   (m_axi_rlast),
      .m_axi_rvalid  (m_axi_rvalid),
      .m_axi_rready  (m_axi_rready)
  );

endmodule : ventium_l1_axi
