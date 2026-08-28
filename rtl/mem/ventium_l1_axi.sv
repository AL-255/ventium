`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
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
    parameter bit          NARROW_REPLAY_SAFE = 1'b0,
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
    // Phase E: the DEFAULT follows the +VEN_EN_L2 build define, so the full-core L1AXI
    // build can turn the L2/northbridge on without editing ventium_top's instantiation.
    // No define → 0 (every existing L1AXI gate + the board build stay byte-identical).
    parameter bit          EN_L2        =
`ifdef VEN_EN_L2
                                          1'b1,
`else
                                          1'b0,
`endif
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
    // ROM windows (0xC0000-0xFFFFF) default to R/W + cacheable ({CE,WE,RE}=0x7 per segment;
    // PAM0=0x70 for 0xF0000, PAM1-6=0x77). The system BIOS is DRAM-backed and no host bridge
    // programs PAM yet, so without this the BIOS executes UNCACHED (every fetch is a bypass→DDR
    // round-trip) — SeaBIOS POST takes tens of minutes. Revert to 0 once ven_hostbridge_cfg is
    // wired so SeaBIOS programs PAM itself (the architecturally-correct reset is uncacheable).
    parameter logic [55:0] NB_PAM     = 56'h77_7777_7777_7770,
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
    output logic        smm_flush_o,     // SMM exit / SMBASE relocation pulse (I-side flush)
    input  logic        golden_l1,       // golden/L1-useless diagnostic mode (flush after each access)
    input  logic        core_req,
    input  logic        core_we,
    input  logic [31:0] core_addr,
    input  logic [31:0] core_lin,    // task #51: pre-translate linear addr of the same access
    // REVIEW2 H-24: the core's live SMM state, for SMRAM open/close in the cache map
    // and northbridge. Was hard-wired 1'b0 at both instances below.
    input  logic        smm_active,
    // REVIEW2_aug2 C-08: the ACTUAL SMRAM base. The guard used to name 0xA0000 --
    // the 82437FX aperture -- which this core does not use for SMM.
    input  logic [31:0] smbase,
    // REVIEW2_aug2 C-10: the core's LOCK for this access. Present so the gap can be
    // MEASURED; deliberately NOT forwarded to AxLOCK -- see the note at its use.
    input  logic        core_lock,
    input  logic [31:0] core_wdata,
    input  logic [3:0]  core_wstrb,
    output logic [31:0] core_rdata,
    // REVIEW2_aug2 H-13: the INSTRUCTION-side memory type for the address currently on
    // the core's bus. 1 = this line must not be retained in the icache. The core ORs it
    // into ic_fill_nocache beside the CR0.CD term, and consumes it only during a fetch
    // fill (S_PF), where core_addr IS the fetch's physical address.
    output logic        core_ic_nocache,
    output logic        core_ack,
    output logic        bus_err,        // #34 fatal AXI fault (watchdog timeout / SLVERR)

    // ---- clean-shutdown quiesce (pass-through to ven_axi_master) ---------------
    input  logic        shutdown,        // 1 = stop new AXI txns, drain in-flight
    output logic        m_idle,          // 1 = AXI master drained -> safe to remove overlay

`ifdef VEN_L1_AXI
    // ---- icache snoop-invalidate (Phase D.6): the SAME northbridge snoop that
    // invalidates ven_l1d, exposed so ventium_top can thread it into the core's
    // icache (DMA-loaded code coherence). 0 when EN_L2=0 / no DMA, so it is inert
    // until the southbridge DMA path is wired. Gated by VEN_L1_AXI so the standalone
    // L1 unit gates (which don't define it) don't need to bind these outputs.
    output logic        icache_snoop_valid,
    output logic [31:0] icache_snoop_addr,
    // REVIEW Aug-1 H-09: two more INDEPENDENT invalidation events per clock (SMC
    // store first line, SMC store second line when it crosses an I-line boundary).
    // See the driver below for why one port could not carry them.
    output logic        icache_snoop_valid1,
    output logic [31:0] icache_snoop_addr1,
    output logic        icache_snoop_valid2,
    output logic [31:0] icache_snoop_addr2,
`endif

`ifdef VEN_NB_DMA
    // ---- Phase D: coherent DMA requester (a non-CPU bus master via the southbridge).
    // Gated by VEN_NB_DMA so ventium_top / the board build are untouched. Only meaningful
    // with EN_L2=1 (the northbridge arbitrates it into the L2 + snoops the L1 on writes).
    input  logic        dma_req,
    input  logic        dma_we,
    input  logic [31:0] dma_addr,
    input  logic [31:0] dma_wdata,
    input  logic [3:0]  dma_wstrb,
    output logic [31:0] dma_rdata,
    output logic        dma_ack,
`endif
`ifdef VEN_NB_MMIO
    // ---- Phase D.5: device MMIO master (to_dram=0 → the southbridge device fabric).
    // Gated by VEN_NB_MMIO so ventium_top / the board build are untouched. Without it,
    // device space falls through to the AXI/DDR backing (pre-D.5 behavior).
    output logic        mmio_req,
    output logic        mmio_we,
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wdata,
    output logic [3:0]  mmio_wstrb,
    input  logic [31:0] mmio_rdata,
    input  logic        mmio_ack,
`endif

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
    ,
    // live CR0.CD (bit30) threaded from the core (ventium_top: core_cr0[30]).
    // REVIEW1_Aug3 R2-H12: UNCONDITIONAL now (was VEN_L1_HONOR_CD) -- CD=1 is the
    // architectural reset/POST state until software clears it, and the deployed
    // build was caching data through it. CD=1 => honor KEN# and bypass the L1 D$
    // (no allocation, no stale serve).
    input  logic        cr0_cd
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
  logic m_rd_narrow; logic [1:0] m_rd_size;  // H-11/R2-H01: L1D -> backing, narrow read request
  logic b_rd_narrow; logic [1:0] b_rd_size;  // H-11/R2-H01: post-L2 (== m_* when EN_L2=0)
  // ===== REVIEW2_aug2 H-13: THE I-SIDE CACHEABILITY QUERY ======================
  // The finding: instruction-fetch cacheability was driven by CR0.CD alone, with no
  // notion of the MEMORY TYPE of the address being fetched. A line in a region the
  // chipset marks non-cacheable (a PAM window opened for a shadowed BIOS write, an
  // MMIO aperture, memory above TOM, an open SMRAM aperture) was cached anyway, so
  // later fetches from it were served from a stale icache copy.
  //
  // This query is DELIBERATELY OUTSIDE the EN_L2 generate block. The D-side one
  // (u_cmap_l1) lives inside it and therefore elaborates only with EN_L2=1 -- that was
  // blocker (2) of this finding: an is_code query added there would be neither built
  // nor tested by any gate in verify-all. Here it is in the DEFAULT build.
  //
  // is_code=1 matters and is not cosmetic: a PAM window set read-only (RE=1, WE=0) is
  // L1-cacheable for CODE reads and not for data, which is exactly the shadowed-BIOS
  // case this decoder exists to model.
  logic core_ic_l1c, core_ic_dram_u, core_ic_l2c_u; logic [3:0] core_ic_region;
  ven_cachemap u_cmap_ic (
      .addr(core_addr), .is_write(1'b0), .is_code(1'b1), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_ic_dram_u), .l1_cacheable(core_ic_l1c), .l2_cacheable(core_ic_l2c_u),
      .region(core_ic_region));
  assign core_ic_nocache = !core_ic_l1c;

  // ===== REVIEW_Aug3 C-01 (item 4): THE D-SIDE CACHEABILITY QUERY =================
  // The finding: with EN_L2=0 and without VEN_L1_HONOR_CD (the DEPLOYED l1axi_kv_full
  // define set has neither), l1d_cacheable was tied 1'b1 in g_nol2 — so a DATA access
  // to memory the chipset marks non-cacheable (the VGA aperture, anything at/above
  // TOM, a closed SMRAM window) was L1-CACHED and its reads went out as amplified
  // 8-beat line fills. The H-11 narrow path (ven_l1d's bypass FSM) was unreachable in
  // exactly the configuration that ships. The I side got its memory-type query in
  // H-13 (u_cmap_ic above); the D side never did.
  //
  // Like u_cmap_ic, this instance is DELIBERATELY OUTSIDE the EN_L2 generate: the
  // g_l2 branch has its own D-side query (u_cmap_l1, feeding ven_l2/ven_northbridge)
  // and is untouched. is_write=core_we so the PAM read-only/write-only attribute of
  // a ROM window is honoured for data cycles; is_code=0 makes a read-only PAM window
  // (shadowed BIOS) non-cacheable for data, per the 82437FX datasheet.
  //
  // CONSEQUENCE of the default NB_* params: the VGA aperture 0xA0000-0xBFFFF and all
  // addresses >= TOM are now non-cacheable on the D side — parity with the I side,
  // and CORRECT for the KV260 fold (the "VRAM" at those addresses is DDR-backed, so
  // caching it would serve stale bytes to the very guests the aperture exists for;
  // MMIO must never be cached regardless). It also means the narrow/bypass path is
  // now live in the DEFAULT build — which is what the L1AXINARROW gate exercises.
  logic core_d_l1c, core_d_dram_u, core_d_l2c_u; logic [3:0] core_d_region;
  ven_cachemap u_cmap_dc (
      .addr(core_addr), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_d_dram_u), .l1_cacheable(core_d_l1c), .l2_cacheable(core_d_l2c_u),
      .region(core_d_region));

  // REVIEW1_Aug3 R2-H02: classify the access EXTENT, not just its first byte.
  // Every cachemap region boundary is 32-byte aligned, so a cache-line FILL can
  // never straddle one -- but an ACCESS (up to 4 bytes, e.g. a dword at 0x9FFD)
  // can cross from cacheable RAM into the VGA aperture, a PAM window, TOM, a
  // hole, or SMRAM. Classifying by the first byte alone allocated and cached the
  // boundary line, hiding device bytes in the D$. Query the map at the LAST byte
  // as well: the access is cacheable only if BOTH endpoints are, otherwise it
  // takes the narrow path (which reads exactly its 1-2 words, never a line).
  // The extent is the highest active strobe for reads AND writes: ven_l1d
  // fragments a strobe'd read into byte-exact pieces, so a byte/word read must
  // not be classified using bytes it will never touch. The +3 whole-word window
  // survives ONLY as the fallback for a read producer that drives no strobes
  // (the legacy whole-word narrow form, which really does span 4 bytes).
  logic [2:0]  core_d_hi;
  logic [31:0] core_d_last;
  always_comb begin
    core_d_hi = 3'd0;
    for (int b = 0; b < 4; b++) if (core_wstrb[b]) core_d_hi = 3'(b);
  end
  assign core_d_last = core_addr + ((core_we || core_wstrb != 4'd0) ? {29'd0, core_d_hi} : 32'd3);
  logic core_d_l1c_last, core_d_dram_last_u, core_d_l2c_last_u; logic [3:0] core_d_region_last;
  ven_cachemap u_cmap_dc_last (
      .addr(core_d_last), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
      .to_dram(core_d_dram_last_u), .l1_cacheable(core_d_l1c_last),
      .l2_cacheable(core_d_l2c_last_u), .region(core_d_region_last));

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
  // KEN# for the L1 D-cache: the D-side ven_cachemap query above (u_cmap_dc) decides
  // cacheability from the memory type, so MMIO is never L1-cached. With the
  // northbridge present (EN_L2) the g_l2 branch substitutes its own query feeding
  // the L2 as well. Driven inside the EN_L2 generate (below) so each configuration
  // has exactly one driver.
  logic l1d_cacheable;
  // REVIEW1_Aug3 R2-H03: sticky routing fault from the no-L2 router (g_nol2 drives
  // it; g_l2 ties it 0 -- the northbridge does its own routing there). ORed into
  // bus_err below in both clock configurations.
  logic route_err;
  // Phase D: northbridge → L1D snoop-invalidate (DMA coherence). Driven in the generate
  // branches (g_l2 → NB snoop; g_nol2 → 0, byte-identical).
  logic        l1d_snoop_valid;
  logic [31:0] l1d_snoop_addr;
  logic [7:0]  l1d_dbg_serve;    // VEN DIAG: ven_l1d {st[2:0],flush_all,rd_match,hit_way,hit1,hit0}
`ifdef VEN_L1_AXI
  // expose the same snoop upward to the core's icache (Phase D.6) AND add SELF-MODIFYING-CODE
  // coherence: invalidate the icache line on EVERY D-side store (core_we/core_addr). Win95's
  // IO.SYS relocates its own code (REP MOVSB to 0x80000) then RETFs into it; the store reaches
  // DDR but the icache/uopcache fetch returned the STALE pre-copy bytes (no SMC snoop) -> wild
  // jump into a keyboard table @cs=8000:0x3a0. Real P5 snoops D-stores against the I-side; this
  // wires the existing (DMA) snoop input to the store address so the relocated-code fetch misses
  // -> refills the freshly-written bytes. Over-invalidates on data stores (harmless re-refill).
  // task #51 FIX: snoop the icache with the LINEAR store address, not the physical one.
  // [... historical note: the linear workaround existed because the icache was
  // linear-TAGGED. REVIEW1_Aug3 R2-H09: the icache now also records each line's
  // PHYSICAL page tag and matches snoops against it, so the snoop returns to the
  // PHYSICAL domain (core_addr) and a store through ANY alias of a physical line
  // drops every aliased copy -- the linear-alias hazard this workaround left open
  // (REVIEW1_Aug2 H-05) is closed. Over-invalidation costs a refill, never
  // correctness. The DMA path (port 0) is physical too and now matches EXACTLY
  // under paging; the conservative full flush on (ic_snoop_valid && paging_on) in
  // core.sv stays as belt-and-braces.]
  // REVIEW Aug-1 H-09: this used to be
  //     valid = l1d_snoop_valid | core_we;
  //     addr  = l1d_snoop_valid ? l1d_snoop_addr : core_lin;
  // which collapsed genuinely INDEPENDENT events onto one address port:
  //   * a DMA snoop and a CPU store in the same clock are two different lines, and
  //     the CPU store's line was silently DROPPED (the ternary picked the DMA one);
  //   * a CPU store that CROSSES a 32-byte instruction-line boundary dirties two
  //     lines, and only the first was ever invalidated.
  // Both leave executable stale bytes resident -- the exact failure mode the SMC
  // snoop was added to prevent (Win95 IO.SYS relocating its own code). The icache
  // now has three independent invalidation ports, so nothing has to be muxed away.
  //
  // core_wstrb gives the store's real byte extent, so the last written byte is
  // core_lin + (index of the highest set strobe). A crossing exists iff that byte
  // lands in a different 32-byte line than core_lin.
  // ===========================================================================
  // REVIEW2_aug2 C-10 -- LOCKED RMW ATOMICITY IS NOT PROVIDED ON THIS PATH.
  //
  // STATUS: OPEN architectural blocker. The local DMA-ownership seam holds the
  // local requester across the window, but PS/global AXI writers do not
  // traverse it and there is no exclusive-access protocol, so this is not
  // architectural LOCK atomicity and must not be counted as LOCK closure. The
  // real fix (AXI4 exclusives end to end, or a common line owner held from
  // locked read through locked write, with explicit abort/reset/timeout
  // release) is deferred with the L2/northbridge work.
  //
  // The core produces mem_lock and bus mode 1 carries it into biu_p5, but the L1/AXI
  // instantiation -- the configuration used for FPGA memory -- had no lock input at
  // all, and ven_axi_master ties ARLOCK/AWLOCK low. A locked read-modify-write is
  // therefore not atomic against DMA or another requester.
  //
  // WHY THE WIRE IS NOT THE FIX, and why AxLOCK stays low: m_axi_{ar,aw}lock here are
  // ONE bit, i.e. AXI4, where that bit means EXCLUSIVE ACCESS -- an exclusive read that
  // arms a monitor, an exclusive write that returns EXOKAY on success or OKAY on
  // failure, and a master that CHECKS the response and retries. Asserting AxLOCK
  // without that handshake is worse than leaving it low: it claims semantics this
  // master does not honour, and a compliant interconnect answering OKAY (failure)
  // would be silently ignored -- atomicity broken while APPEARING to be requested.
  //
  // The two real options (both in the review) are carrying lock ownership through
  // L1D/L2/arbitration so the bus is held across the RMW, or implementing AXI4
  // exclusive access properly. Both are protocol work, not a connection.
  //
  // So the gap is made MEASURABLE instead of papered over: count the locked core
  // requests that traverse this path. With the R2-H08 ownership FSM (below, at
  // the DMA ingress) the local requester is held across the window in every
  // VEN_NB_DMA configuration, so this counter now measures locked TRAFFIC, not
  // unprotected traffic; it hits zero only on workloads with no LOCK prefix.
  logic        c10_lock_unprotected;
  assign c10_lock_unprotected = core_req && core_lock;

`ifndef SYNTHESIS
  int   ven_c10_n;
  logic ven_c10log_en;
  initial begin ven_c10log_en = $test$plusargs("ven_locklog") != 0; ven_c10_n = 0; end
  always_ff @(posedge core_clk)
    if (core_rst_n && c10_lock_unprotected && core_ack) ven_c10_n <= ven_c10_n + 1;
  final if (ven_c10log_en)
    $display("[C10LOCK] locked accesses with NO bus exclusion: %0d", ven_c10_n);
`endif

  logic [31:0] smc_last_lin;
  logic [31:0] smc_last_phys;   // R2-H09
  logic        smc_xline;
  always_comb begin
    logic [2:0] hi;
    hi = 3'd0;
    for (int b = 0; b < 4; b++) if (core_wstrb[b]) hi = 3'(b);
    smc_last_lin  = core_lin  + {29'd0, hi};
    // R2-H09: the last byte's PHYSICAL address. A line-crossing store that also
    // crosses a PAGE is split by the fx engine into per-page beats upstream, so
    // the bytes this beat covers are always page-contiguous and +hi is exact.
    smc_last_phys = core_addr + {29'd0, hi};
  end
  assign smc_xline = core_we && (smc_last_lin[31:5] != core_lin[31:5]);

  assign icache_snoop_valid  = l1d_snoop_valid;   // port 0: DMA / northbridge
  assign icache_snoop_addr   = l1d_snoop_addr;
  assign icache_snoop_valid1 = core_we;           // port 1: SMC store, first line
  assign icache_snoop_addr1  = core_addr;         // R2-H09: PHYSICAL (ic_ptag match)
  assign icache_snoop_valid2 = smc_xline;         // port 2: SMC store, second line
  assign icache_snoop_addr2  = smc_last_phys;     // R2-H09: PHYSICAL
`endif
  // DMA requester into the northbridge: from the external port (VEN_NB_DMA) or tied off
  // (CPU-only). Responses (rdata/ack) are driven by the generate (NB present or 0).
  logic        nb_dma_req, nb_dma_we; logic [31:0] nb_dma_addr, nb_dma_wdata; logic [3:0] nb_dma_wstrb;
  logic [31:0] nb_dma_rdata; logic nb_dma_ack;

  // ===========================================================================
  // REVIEW1_Aug3 R2-H08 -- LOCKED-RMW OWNERSHIP of the local DMA requester.
  // (Deliberately OUTSIDE every ifdef: the ports it reads always exist.)
  //
  // While a locked core sequence is in flight -- a locked READ accepted, the
  // matching locked WRITE not yet completed -- a DMA transaction must not start:
  // nb_dma_req is held low, so the requester's write can never land between the
  // RMW's read and write beats. (The pin-level biu_p5 path already holds LOCK#
  // across the pair; the pinless L1/AXI path now has the equivalent ownership.)
  //
  //   set:      a locked read is ACKED (its data is about to be consumed)
  //   release:  the locked write is ACKED (sequence complete)
  //             ANY unlocked core request (the sequence aborted -- e.g. a fault
  //             between the beats reroutes the core to delivery traffic, which
  //             is never lock-marked; holding the port then would wedge DMA
  //             forever)
  //             reset
  //
  // SCOPE, honestly: in this checkout's only buildable configuration (no-L2)
  // the DMA path is tied off below, so this hold is inert today -- it exists
  // for the VEN_NB_DMA/northbridge configurations where a second requester is
  // real, and it is FSM-tested by run-l1axi-lock-gate.sh. AXI4-exclusive
  // (AxLOCK/EXOKAY) is deliberately NOT asserted (see the C-10 note above): the
  // only requesters behind this module are local, and the PS side reaches DDR
  // without traversing this fabric at all.
  //
  // ACQUISITION (Aug4 follow-up). The hold used to open only at the read's
  // ACK, so a DMA request asserted before or during the read's latency could
  // still be granted inside the RMW. The fabric is now RESERVED the cycle the
  // locked read is ASSERTED (combinationally for that first cycle, registered
  // after as lock_pend), so no new DMA grant can start from the assertion
  // onward. The reservation gates NEW selections only: a request the seam
  // already forwarded is an ACCEPTED transaction and must run to its ack --
  // see the dma_inflight ownership below.
  logic lock_owned, lock_pend;
  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin
      lock_owned <= 1'b0; lock_pend <= 1'b0;
    end else begin
      if (core_req && !core_lock) begin
        lock_owned <= 1'b0; lock_pend <= 1'b0;            // aborted sequence
      end else if (core_req && core_lock &&  core_we && core_ack) begin
        lock_owned <= 1'b0; lock_pend <= 1'b0;            // done
      end else if (core_req && core_lock && !core_we && core_ack) begin
        lock_owned <= 1'b1; lock_pend <= 1'b0;            // window opens
      end else if (core_req && core_lock && !core_we) begin
        lock_pend <= 1'b1;                                // read asserted: reserve
      end
    end
  logic dma_blk;
  assign dma_blk = lock_owned || lock_pend || (core_req && core_lock);

`ifdef VEN_NB_DMA
  // DMA IN-FLIGHT OWNERSHIP. A DMA request the seam forwards is an ACCEPTED
  // transaction: req/ack forbids withdrawing it, so nb_dma_req and the payload
  // hold stable from the forwarding cycle until nb_dma_ack (or reset -- the
  // defined abort response; there is no cancel handshake on these ports).
  // dma_blk gates NEW selections only, never the in-flight one. New-selection
  // priority when a fresh DMA request and a locked core request arrive on the
  // same cycle: the LOCK wins (dma_blk's combinational term) -- a lock
  // reservation never waits behind traffic that has not started, and a locked
  // read arriving while a DMA beat owns the seam is held out of the L1 until
  // the drain (dma_drain_stall at the request interpose below), so no DMA
  // completion can land inside the RMW window.
  logic        dma_inflight;
  logic        dma_we_q;
  logic [31:0] dma_addr_q, dma_wdata_q;
  logic [3:0]  dma_wstrb_q;
  wire         dma_sel = dma_req && !dma_blk;            // a NEW selection this cycle
  assign nb_dma_req   = dma_inflight || dma_sel;
  assign nb_dma_we    = dma_inflight ? dma_we_q    : dma_we;
  assign nb_dma_addr  = dma_inflight ? dma_addr_q  : dma_addr;
  assign nb_dma_wdata = dma_inflight ? dma_wdata_q : dma_wdata;
  assign nb_dma_wstrb = dma_inflight ? dma_wstrb_q : dma_wstrb;
  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin
      dma_inflight <= 1'b0;
      dma_we_q <= 1'b0; dma_addr_q <= 32'd0; dma_wdata_q <= 32'd0; dma_wstrb_q <= 4'd0;
    end else if (dma_inflight) begin
      if (nb_dma_ack) dma_inflight <= 1'b0;
    end else if (dma_sel && !nb_dma_ack) begin
      dma_inflight <= 1'b1;
      dma_we_q     <= dma_we;
      dma_addr_q   <= dma_addr;
      dma_wdata_q  <= dma_wdata;
      dma_wstrb_q  <= dma_wstrb;
    end
  assign dma_rdata = nb_dma_rdata; assign dma_ack = nb_dma_ack;
  wire dma_seam_busy = dma_inflight;
`else
  assign nb_dma_req = 1'b0; assign nb_dma_we = 1'b0; assign nb_dma_addr = 32'd0;
  assign nb_dma_wdata = 32'd0; assign nb_dma_wstrb = 4'd0;
  wire dma_seam_busy = 1'b0;
`endif

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
  // REVIEW_Aug3 C-01: the H-11 narrow-read bits reach ven_axi_master through the SAME
  // static compile-time selection as the rest of the request — latched out of the
  // command FIFO by ven_axi_cdc in the dual-clock build, wired straight through
  // otherwise. They USED to be consumed from b_rd_narrow directly (ventium_l1_axi's
  // m_rd_narrow port connection): correct in the single-clock build, but under
  // VEN_AXI_CDC the request had crossed to the axi_clk domain through the command
  // FIFO while its shape bits had not — a metadata race.
  logic        axm_rd_narrow;  logic [1:0] axm_rd_size;

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
      // C-01: the narrow-read shape crosses INSIDE the command record
      .c_rd_narrow(b_rd_narrow), .c_rd_size   (b_rd_size),
      .c_ack      (b_ack),  .bus_err (cdc_bus_err_w),
      // axi side: drives ven_axi_master's backing slave
      .a_req      (axm_req),  .a_we    (axm_we),    .a_addr  (axm_addr),
      .a_wdata    (axm_wdata),.a_wstrb (axm_wstrb), .a_rdata (axm_rdata),
      .a_rd_narrow(axm_rd_narrow), .a_rd_size   (axm_rd_size),
      .a_ack      (axm_ack),  .a_bus_err(axm_bus_err)
  );
  // R2-H03: the no-L2 router's sticky fault joins the AXI master's errors.
  logic cdc_bus_err_w;
  assign bus_err = cdc_bus_err_w | route_err;
`else
  // ---- default single-clock (CDC_BYPASS): wire the post-L2 backing straight through.
  assign l1d_rst_n = core_rst_n;
  assign axm_clk   = core_clk;
  assign axm_rst_n = core_rst_n;
  // REVIEW2_aug2 H-11: the narrow-read request width, from ven_l1d to ven_axi_master.
  // It is passed through ONLY on the L2-BYPASS path (EN_L2=0). A line-based L2 has no
  // meaning for a narrow, non-cacheable access -- and non-cacheable traffic should not
  // be entering the L2 in the first place -- so with the northbridge in the datapath
  // these are tied 0 and the behaviour there is exactly what it was. That keeps this
  // change inside the configuration whose gates actually run it, rather than making an
  // untested claim about the L2 build.
  assign axm_req   = b_req;   assign axm_we    = b_we;
  assign axm_addr  = b_addr;  assign axm_wdata = b_wdata;  assign axm_wstrb = b_wstrb;
  assign b_rdata   = axm_rdata; assign b_ack   = axm_ack;
  assign bus_err   = axm_bus_err | route_err;   // R2-H03: + the no-L2 router fault
  // C-01: same domain, so the passthrough is just a wire (the CDC build above gets
  // them out of the command FIFO instead).
  assign axm_rd_narrow = b_rd_narrow;  assign axm_rd_size   = b_rd_size;
`endif

  // ---- L2 splice (Phase B): EN_L2=0 → transparent (b_* = m_*); EN_L2=1 → ven_l2
  // sits between the L1's backing master (m_*) and the AXI/CDC path (b_*). ven_l2 is
  // a proven drop-in for this exact word-granular backing protocol on both ports
  // (verif/l1/run-l2-axi-gate.sh ran it end-to-end through the real ven_axi_master).
  generate
    if (EN_L2) begin : g_l2
      // DISABLED FOR NOW (REVIEW_Aug3 H-09): the L2/northbridge sources
      // (ven_l2.sv / ven_northbridge.sv) are absent from this checkout and the
      // EN_L2=1 configuration is deliberately OFF until they land. Fail loudly at
      // elaboration rather than letting a direct +define+VEN_EN_L2 build die on
      // missing modules with no explanation.
`ifndef SYNTHESIS
      initial $fatal(1, "ventium_l1_axi: EN_L2=1 is DISABLED FOR NOW -- the L2/northbridge sources are absent from this checkout (REVIEW_Aug3 H-09, task #43). Build the default EN_L2=0 configuration.");
`endif
      // KEN# for the L1 D-cache (data path; is_code=0) — MMIO is never L1-cached.
      // REVIEW2 H-17 cited this is_code(1'b0) as evidence, and it is correct FOR THIS
      // QUERY: u_cmap_l1 feeds l1d_cacheable -> ven_l1d, i.e. the D-cache's own KEN#.
      // The real gap was that no I-side decision existed ANYWHERE. That is now owned
      // by the core: icache has a fill_nocache input and refuses to validate a fill
      // whose line must not be retained (core.sv, ic_fill_nocache), enforcing CR0.CD.
      // What is STILL missing is the memory-TYPE half -- a second query with
      // is_code(1'b1) over the fetch address, whose result would OR into the core's
      // ic_fill_nocache.
      //
      // REVIEW2_aug2 H-13, re-verified rather than repeated. The CR0.CD half is now the
      // DEFAULT (c78c576); this half has TWO independent blockers, and both still hold:
      //   1. ven_cachemap's module source is not under rtl/ on THIS branch. My earlier
      //      note called the only copy "an agent scratch worktree ... a provenance
      //      question"; that was WRONG and I am correcting it rather than leaving it.
      //      The module is properly committed -- c8dbf3b "northbridge: cacheability map
      //      + L1/L2 integration gates (Phase A/B)" -- and lives on real branches
      //      including soc-northbridge-v1. The worktree copy is just a checkout of it.
      //      Verified NOT an ancestor of HEAD, so the original PROGRESS wording
      //      ("on an unmerged branch") was the accurate one.
      //      That makes step 1 a MERGE decision -- which branch state ships -- not a
      //      technical blocker and not mine to take unilaterally mid-review.
      //   2. Even with the module, this whole generate branch elaborates only under
      //      EN_L2=1, so an is_code query added here would be neither built nor tested
      //      by any gate in verify-all.
      // Neither is something the core side can route around: there is no region
      // information anywhere in core.sv to OR into ic_fill_nocache.
      //
      // With the correction above, the chain is now concrete rather than vague, and
      // whoever owns the branch decision can price it: (a) land ven_cachemap on this
      // branch; (b) instantiate an is_code(1'b1) query OUTSIDE the EN_L2 generate
      // block, since the existing D-side one only elaborates with EN_L2=1 and the
      // default build needs it; (c) add a core input and OR it into ic_fill_nocache
      // beside the CR0.CD term that shipped in c78c576. Steps (b) and (c) are ordinary
      // work; (a) is the decision.
      logic core_l1c, core_to_dram_u, core_l2c_u; logic [3:0] core_cm_region;
      ven_cachemap u_cmap_l1 (
          .addr(core_addr), .is_write(core_we), .is_code(1'b0), .smm_active(smm_active),
          .pam(NB_PAM), .dramc(NB_DRAMC), .cc(NB_CC), .tom_mb4(NB_TOM_MB4), .smram(NB_SMRAM),
          .to_dram(core_to_dram_u), .l1_cacheable(core_l1c), .l2_cacheable(core_l2c_u),
          .region(core_cm_region));
      assign l1d_cacheable = core_l1c;
      assign route_err = 1'b0;   // R2-H03: the northbridge does its own routing here
      // NB downstreams: nb_d_* = DDR (L2 + DRAM-bypass), nb_mmio_* = device MMIO (D.5).
      logic        nb_d_req, nb_d_we; logic [31:0] nb_d_addr, nb_d_wdata; logic [3:0] nb_d_wstrb;
      logic [31:0] nb_d_rdata; logic nb_d_ack;
      logic        nb_mmio_req, nb_mmio_we; logic [31:0] nb_mmio_addr, nb_mmio_wdata; logic [3:0] nb_mmio_wstrb;
      logic [31:0] nb_mmio_rdata; logic nb_mmio_ack;
      // Phase C: the northbridge (cachemap + L2 + uncacheable bypass + MMIO split).
      ven_northbridge #(.L2_CAP_BYTES(L2_CAP_BYTES), .L2_LINE(L1_LINE), .L2_WAYS(L2_WAYS)) u_nb (
          .clk   (core_clk),
          .rst_n (l1d_rst_n),       // L2's own reset (NOT gated on its own ready)
          .ready (l2_ready),
          .cfg_pam(NB_PAM), .cfg_dramc(NB_DRAMC), .cfg_cc(NB_CC),
          .cfg_tom_mb4(NB_TOM_MB4), .cfg_smram(NB_SMRAM), .smm_active(smm_active),
          // upstream slave ⇐ the L1's backing master
          .u_req (m_req),  .u_we (m_we),  .u_addr (m_addr), .u_wdata (m_wdata),
          .u_wstrb(m_wstrb), .u_rdata(m_rdata), .u_ack (m_ack),
          // DDR downstream master ⇒ the AXI master / CDC backing slave
          .d_req (nb_d_req),  .d_we (nb_d_we),  .d_addr (nb_d_addr), .d_wdata (nb_d_wdata),
          .d_wstrb(nb_d_wstrb), .d_rdata(nb_d_rdata), .d_ack (nb_d_ack),
          // coherent DMA requester + snoop broadcast (Phase D)
          .dma_req(nb_dma_req), .dma_we(nb_dma_we), .dma_addr(nb_dma_addr),
          .dma_wdata(nb_dma_wdata), .dma_wstrb(nb_dma_wstrb),
          .dma_rdata(nb_dma_rdata), .dma_ack(nb_dma_ack),
          .snoop_inv_valid(l1d_snoop_valid), .snoop_inv_addr(l1d_snoop_addr),
          // MMIO downstream master ⇒ device fabric (southbridge) — D.5
          .mmio_req(nb_mmio_req), .mmio_we(nb_mmio_we), .mmio_addr(nb_mmio_addr),
          .mmio_wdata(nb_mmio_wdata), .mmio_wstrb(nb_mmio_wstrb),
          .mmio_rdata(nb_mmio_rdata), .mmio_ack(nb_mmio_ack)
`ifdef VEN_DBG_CORE
          , .dbg_hits(l2_hits_w), .dbg_misses(l2_misses_w), .dbg_wbacks(l2_wbacks_w),
            .dbg_bypass(l2_bypass_w)
`endif
      );
`ifdef VEN_NB_MMIO
      // device MMIO exits on the external port; DDR path goes to the AXI master.
      assign b_rd_narrow = 1'b0; assign b_rd_size = 2'd0;   // H-11: not through the L2
      assign b_req = nb_d_req; assign b_we = nb_d_we; assign b_addr = nb_d_addr;
      assign b_wdata = nb_d_wdata; assign b_wstrb = nb_d_wstrb;
      assign nb_d_rdata = b_rdata; assign nb_d_ack = b_ack;
      assign mmio_req = nb_mmio_req; assign mmio_we = nb_mmio_we; assign mmio_addr = nb_mmio_addr;
      assign mmio_wdata = nb_mmio_wdata; assign mmio_wstrb = nb_mmio_wstrb;
      assign nb_mmio_rdata = mmio_rdata; assign nb_mmio_ack = mmio_ack;
`else
`ifndef VEN_NB_MMIO_TO_DDR_OK
      // REVIEW2 M-06: this silently sends DEVICE accesses to DDR. Firmware then
      // appears to run while every device side effect is lost -- a read returns
      // whatever RAM holds at the device address and a write scribbles on it. That is
      // strictly worse than not building: a bus fault or a build error is diagnosable,
      // a silent aliasing of MMIO onto RAM is not.
      //
      // So the fallthrough is now OPT-IN. If you genuinely want it (bring-up without a
      // device fabric, where nothing touches MMIO), define VEN_NB_MMIO_TO_DDR_OK and
      // accept that device space is RAM. Otherwise build with VEN_NB_MMIO and provide
      // the external fabric.
      $fatal(1, "ventium_l1_axi: EN_L2=1 without VEN_NB_MMIO -- device MMIO would silently alias onto DDR (REVIEW2 M-06). Define VEN_NB_MMIO for a real device fabric, or VEN_NB_MMIO_TO_DDR_OK to accept the aliasing deliberately.");
`endif
      // no external device fabric in this build: MERGE the MMIO master back onto the
      // single AXI backing (device space falls through to DDR — keeps the pre-D.5 gates
      // byte-identical, since only one of nb_d_*/nb_mmio_* is ever active at a time).
      assign b_rd_narrow = 1'b0; assign b_rd_size = 2'd0;   // H-11: not through the L2
      assign b_req   = nb_d_req | nb_mmio_req;
      assign b_we    = nb_mmio_req ? nb_mmio_we    : nb_d_we;
      assign b_addr  = nb_mmio_req ? nb_mmio_addr  : nb_d_addr;
      assign b_wdata = nb_mmio_req ? nb_mmio_wdata : nb_d_wdata;
      assign b_wstrb = nb_mmio_req ? nb_mmio_wstrb : nb_d_wstrb;
      // route the shared backing response to BOTH (ungated — the NB's stable mmio_sel
      // picks which one matters; only one path is active per single-outstanding txn).
      // Gating by *_req here would drop the ack when the requester deasserts at the ack
      // edge → the NB lock would stick (the same footgun as the snoop latch).
      assign nb_d_rdata    = b_rdata; assign nb_d_ack    = b_ack;
      assign nb_mmio_rdata = b_rdata; assign nb_mmio_ack = b_ack;
`endif
    end else begin : g_nol2
      // L2 bypassed: the backing port is transparent (byte-identical to pre-L2).
      // REVIEW1_Aug2 H-08: this branch is the one that BUILDS, and it consumed
      // smm_active nowhere -- so the A0000-BFFFF SMRAM aperture was reachable by
      // ordinary (non-SMM) code. SMM's entire security model is that its RAM is
      // invisible outside SMM; without this the handler's code and saved state can be
      // read or rewritten by the guest. The EN_L2=1 branch enforces it through
      // ven_cachemap, but those sources are on an unmerged branch (see PROGRESS §4f),
      // so the buildable path needs the check itself.
      //
      // 82437FX SMRAM register (0x72): bit 3 = DEN (SMM space enabled), bit 6 = DOPEN
      // (aperture forced open so the BIOS can initialise it). DRAM-backed iff
      // DEN && (DOPEN || in SMM) -- so a NON-SMM access with DEN set and DOPEN clear
      // must NOT reach DRAM.
      //
      // Denied accesses are completed as an unbacked aperture (reads 0, writes
      // dropped) rather than stalled. That is deliberate: real hardware forwards them
      // to the video aperture, there is no PCI path in this config to forward to, and
      // withholding the ack would HANG the core -- which is exactly how the H-07
      // attempt failed. The ack is registered rather than combinational so it cannot
      // form a loop with the requester's req-until-ack handshake.
      //
      // INERT AT THE DEFAULT NB_SMRAM=8'h00 (DEN=0): byte-identical to before unless
      // a configuration actually enables SMRAM.
      logic smram_deny, smram_deny_q;
      // REVIEW2_aug2 C-08: guard the window SMM ACTUALLY occupies -- [SMBASE,
      // SMBASE+0xFFFF]. The handler entry is SMBASE+0x8000 and the state save map is
      // SMBASE+0xFE00..+0xFFFF, so with the default SMBASE=0x30000 the real region is
      // 0x30000-0x3FFFF and the old 0xA0000-0xBFFFF guard protected nothing that
      // mattered: ordinary guest code could read or rewrite the SMM handler and the
      // saved CPU state.
      //
      // The extent is the highest active strobe, reads AND writes: the narrow
      // path hands this seam byte-exact 1/2/4-byte pieces, so a piece wholly
      // below the window must not be denied for bytes it never touches (the
      // same misclassification class as the core-side extent -- a byte read at
      // smbase-1 would otherwise return aperture zeros instead of DRAM). The
      // +3 whole-word window survives only as the zero-strobe fallback (a
      // legacy whole-word beat really does span 4 bytes).
      logic [2:0] m_d_hi;
      always_comb begin
        m_d_hi = 3'd0;
        for (int b = 0; b < 4; b++) if (m_wstrb[b]) m_d_hi = 3'(b);
      end
      assign smram_deny = NB_SMRAM[3] && !NB_SMRAM[6] && !smm_active
                       && ((m_addr + ((m_we || m_wstrb != 4'd0) ? {29'd0, m_d_hi} : 32'd3))
                           >= smbase)
                       && (m_addr <= (smbase + 32'h0000_FFFF));
      // REVIEW1_Aug3 R2-H02: the deny is EXTENT-aware -- a beat whose window
      // straddles INTO the aperture from below it is denied, which the
      // start-address-only check let through.
      always_ff @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) smram_deny_q <= 1'b0;
        else             smram_deny_q <= m_req && smram_deny && !smram_deny_q;

      // ===== REVIEW1_Aug3 R2-H03: THE NO-L2 ROUTER ===============================
      // u_cmap_dc's to_dram output was produced but never consumed: every non-denied
      // request went to DDR regardless, silently aliasing device/unmapped space (PCI
      // aperture, memory holes, disabled-PAM windows) onto RAM. Route explicitly:
      //   * to_dram=1                          -> DDR (the AXI master), as before;
      //   * region == R_VID (4'd2, 0xA0000-0xBFFFF) -> DDR BY PLATFORM OVERRIDE:
      //     the KV260 fold backs "VRAM" with the DDR carveout (fb_vnc reads it
      //     there), so video traffic is DDR traffic here -- that is an EXPLICIT
      //     platform choice, recorded, not a default;
      //   * region == R_PCI (4'd6, >= TOM)     -> DDR ONLY INSIDE THE DECLARED
      //     RAM WINDOW. This platform's "DRAM" is whatever the address fold
      //     serves, and ven_axi_master enforces exactly that envelope at the
      //     access (ADDR_MASK, plus the top-of-4G BIOS shadow the fold exists
      //     for). The router now applies the SAME envelope: inside the window
      //     (or in the shadow) region 6 is DDR; anything else in region 6 is
      //     a genuine PCI/unmapped access and takes the loud route_bad path
      //     instead of aliasing onto RAM. With the flat full-mask build the
      //     whole 32-bit space is inside the window (unchanged behavior);
      //     the KV260 256 MiB mask narrows the contract to the carveout plus
      //     the shadow, matching the master exactly.
      //   * anything else non-DRAM (a memory HOLE or a disabled-PAM window)
      //     -> NO DEVICE FABRIC EXISTS in this build, so the access must fail
      //     LOUDLY rather than read/write RAM: the request is suppressed (acked
      //     locally like smram_deny so the pipeline never wedges) and a sticky
      //     route_err feeds bus_err -> the core halts.
      // NOTE: with the default NB_* params only VGA and R_PCI decode non-DRAM,
      // so the error path is inert until a PAM/hole config creates such a region.
      logic route_bad, route_bad_q;
      logic ep_ok_first, ep_ok_last;
      logic pci_ok_first, pci_ok_last;
      assign pci_ok_first = (core_d_region == 4'd6)
                         && ( ((core_addr    & ~ADDR_MASK) == 32'd0)
                            || (core_addr    >= 32'hFFFE_0000) );
      assign pci_ok_last  = (core_d_region_last == 4'd6)
                         && ( ((core_d_last  & ~ADDR_MASK) == 32'd0)
                            || (core_d_last  >= 32'hFFFE_0000) );
      assign ep_ok_first = core_d_dram_u
                        || (core_d_region      == 4'd2) || pci_ok_first;
      assign ep_ok_last  = core_d_dram_last_u
                        || (core_d_region_last == 4'd2) || pci_ok_last;
      assign route_bad   = m_req && !(ep_ok_first && ep_ok_last);
      always_ff @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin route_bad_q <= 1'b0; route_err <= 1'b0; end
        else begin
          route_bad_q <= m_req && route_bad && !route_bad_q;
          if (route_bad) route_err <= 1'b1;
`ifndef SYNTHESIS
          if (route_bad)
            $display("[L1AXI] R2-H03 ROUTE-ERR: request addr=%08h (last=%08h) targets non-DRAM, non-VGA space (to_dram=0) with NO device fabric in the no-L2 build -- raising bus_err instead of aliasing it onto DDR.",
                     m_addr, core_d_last);
`endif
        end

      assign b_rd_narrow   = m_rd_narrow;      // H-11: L2 bypassed -> pass it through
      assign b_rd_size    = m_rd_size;
      assign b_req = m_req && !smram_deny && !route_bad;
      assign b_we  = m_we  && !smram_deny && !route_bad;
      assign b_addr = m_addr;
      assign b_wdata = m_wdata;
      assign b_wstrb = (smram_deny || route_bad) ? 4'd0 : m_wstrb;
      assign m_rdata = (smram_deny_q || route_bad_q) ? 32'd0 : b_rdata;
      assign m_ack   = (smram_deny_q || route_bad_q) ? 1'b1  : b_ack;
      assign l2_ready = 1'b1;
`ifdef VEN_L1_IGNORE_CD
      // EXPERIMENT (task #24). Forces write-allocate ON regardless of CR0.CD.
      // NOT SHIPPABLE: ignoring CD is an architectural regression (ao486 honours
      // it too, tlb.v:562). Kept EXPERIMENT-ONLY (REVIEW1_Aug3 R2-H12).
      assign l1d_cacheable = 1'b1;
`else
      // REVIEW1_Aug3 R2-H12 + R2-H02: the effective D-side policy is now ONE
      // expression, unconditional (the VEN_L1_HONOR_CD define is retired to a
      // no-op): an access is cacheable iff the MEMORY TYPE of BOTH its first and
      // last byte allows it (R2-H02) AND CR0.CD is clear (R2-H12 -- CD=1 is the
      // reset/POST state, and the deployed build was allocating through it).
      assign l1d_cacheable = core_d_l1c && core_d_l1c_last && ~cr0_cd;
`endif
      assign l1d_snoop_valid = 1'b0; assign l1d_snoop_addr = 32'd0;   // no snoop (no DMA path)
      assign nb_dma_rdata = 32'd0; assign nb_dma_ack = 1'b0;          // no DMA path
`ifdef VEN_NB_MMIO
      assign mmio_req=1'b0; assign mmio_we=1'b0; assign mmio_addr=32'd0;
      assign mmio_wdata=32'd0; assign mmio_wstrb=4'd0;                // no NB → no MMIO master
`endif
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

  // Pre-lookup SMRAM enforcement. The backing-seam deny (smram_deny, on m_req)
  // runs AFTER ven_l1d has looked up or updated its arrays, so with only that
  // guard a non-SMM access to the window can HIT a line filled while in SMM, a
  // write-hit can poison a line whose backing store is then denied, and a
  // denied read-miss can fill a line of zeros. Compute the access result
  // BEFORE the L1: a denied core access never enters ven_l1d at all -- it is
  // acked locally with rdata=0, the same open-bus form the backing deny uses.
  // INERT at the default NB_SMRAM=8'h00 (byte-identical, like the backing one).
  logic core_smram_deny;
  assign core_smram_deny = NB_SMRAM[3] && !NB_SMRAM[6] && !smm_active
                        && (core_d_last >= smbase)
                        && (core_addr   <= (smbase + 32'h0000_FFFF));
  // ...and a conservative full flush on every policy-relevant transition the
  // core reports: SMM exit (lines filled while in SMM must not stay readable
  // or executable once the window closes) and SMBASE relocation. The runtime
  // chipset close/lock register does not exist in this checkout (platform
  // work); when it lands it must pulse this same trigger.
  logic smm_active_q; logic [31:0] smbase_q;
  always_ff @(posedge core_clk or negedge core_rst_n)
    if (!core_rst_n) begin smm_active_q <= 1'b0; smbase_q <= 32'd0; end
    else begin smm_active_q <= smm_active; smbase_q <= smbase; end
  logic smm_flush;
  assign smm_flush  = (smm_active_q && !smm_active) || (smbase_q != smbase);
  assign smm_flush_o = smm_flush;

  // the L1-side request/response interpose: denied accesses stop here. The
  // local ack is qualified with core_req: an unqualified one stays set after
  // the denied requester drops its request, and the NEXT access (to the same
  // address with the policy now open) would capture the stale ack and its
  // zero rdata instead of running its own transaction.
  //
  // dma_drain_stall: a locked core request must not complete while a DMA
  // transaction owns the forwarded seam -- the RMW window opens at the read's
  // completion, and a DMA beat draining after it would land inside the
  // window. The locked request is held out of the L1 (and the local deny
  // ack) until the in-flight DMA acks; dma_blk's lock_pend term already
  // blocks new DMA selections, so the drain is the only remaining beat.
  // (Inert without VEN_NB_DMA: dma_seam_busy is tied 0.)
  logic dma_drain_stall;
  assign dma_drain_stall = core_lock && dma_seam_busy;
  logic l1d_c_req; logic l1d_c_ack; logic [31:0] l1d_c_rdata;
  assign l1d_c_req  = core_req && !core_smram_deny && !dma_drain_stall;
  assign core_ack   = dma_drain_stall ? 1'b0
                    : (core_smram_deny && core_req) ? 1'b1 : l1d_c_ack;
  assign core_rdata = core_smram_deny ? 32'd0 : l1d_c_rdata;

  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (
      .clk      (core_clk),
      // hold the L1 (and thus the core, which stalls on c_ack) in reset until the L2
      // has finished its post-reset valid-clear walk (l2_ready). EN_L2=0 → l2_ready=1
      // → this is exactly l1d_rst_n (byte-identical).
      .rst_n    (l1d_rst_n & l2_ready),
      .flush_all(flush_all || smm_flush),
      .golden   (golden_l1),
      // Phase C: KEN# from the D-side cachemap (u_cmap_dc in the default build,
      // u_cmap_l1 with EN_L2) so MMIO is never L1-cached. Phase D: snoop-invalidate
      // driven by the northbridge on DMA writes (EN_L2=0 → 0, byte-identical).
      .cacheable      (l1d_cacheable),
      .snoop_inv_valid(l1d_snoop_valid),
      .snoop_inv_addr (l1d_snoop_addr),
      .c_req   (l1d_c_req),
      .c_we    (core_we),
      .c_addr  (core_addr),
      .c_wdata (core_wdata),
      .c_wstrb (core_wstrb),
      .c_rdata (l1d_c_rdata),
      .c_ack   (l1d_c_ack),
      .dbg_serve (l1d_dbg_serve),
      .m_req   (m_req),
      .m_we    (m_we),
      .m_addr  (m_addr),
      .m_wdata (m_wdata),
      .m_wstrb (m_wstrb),
      .m_rdata (m_rdata),
      .m_rd_narrow   (m_rd_narrow),
      .m_rd_size   (m_rd_size),
      .m_ack   (m_ack)
  );

  ven_axi_master #(
      .LINE_BEATS (L1_LINE/4),
      .ADDR_W     (ADDR_W),
      .REMAP_BASE (REMAP_BASE),
      .ADDR_MASK  (ADDR_MASK),
      .AXI_ID     (AXI_ID),
      .NARROW_REPLAY_SAFE (NARROW_REPLAY_SAFE),
      .WATCHDOG   (WATCHDOG)
  ) u_axi (
      .core_clk    (axm_clk),
      .core_rst_n  (axm_rst_n),
      .axi_clk     (axi_clk),
      .axi_rst_n   (axi_rst_n),
      .m_rd_narrow   (axm_rd_narrow),     // C-01: crossed with the request, not beside it
      .m_rd_size   (axm_rd_size),
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
      // VEN DIAG (load-serve forensics): the AXI-master fill tap is DISCONNECTED here; the dbg_rd ring
      // is retargeted below to the CORE READ-SERVE (c_addr/c_rdata) so it shows what the L1D actually
      // DELIVERS to a load (not the fill). Distinguishes serve-stale (addr=0x910 & data=scancode-table)
      // from an addressing bug (addr != 0x910). Confirms/denies the faithful-chain inference c_rdata==
      // m_axi_wdata for the REP MOVSB relocation store.
      .dbg_rd_valid (axm_dbg_rv),
      .dbg_rd_addr  (axm_dbg_ra),
      .dbg_rd_data  (axm_dbg_rd),
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

`ifdef VEN_DBG_CORE
  // VEN DIAG (load-serve forensics): retarget the dbg_rd ring to the CORE READ-SERVE. dbg_rd_data =
  // c_rdata (the 4 bytes the L1D delivers to the load at core_addr); dbg_rd_addr = core_addr. Pulsed on
  // a completed READ (core_req & ~core_we & core_ack). With the AW-to-0x80240 freeze, the ring holds the
  // MOVSB source-load serves for the copy region -> proves whether c_rdata for 0x910 is CODE or a TABLE.
  wire        axm_dbg_rv;
  wire [31:0] axm_dbg_ra, axm_dbg_rd;
  // pack the L1D serve state {rd_match,hit_way,hit1,hit0} into the free top nibble of the (guest<256MB)
  // address so ONE ring entry carries addr + c_rdata + the hit-state that explains the serve.
  // build #14: capture WRITES (core_we) with the hit state, to see if the kernel-load store to 0xb00
  // HITS the stale zero cache line (=> a deeper RMW/invalidate/hit-detect bug) or MISSES it (=> the zero
  // fill happened after the store / an ordering issue). data=core_wdata (the store bytes = should be CODE).
  // build #15: capture BOTH reads and writes to 0xb00..0xb3f in ONE run to resolve the cross-run ordering
  // (does a CODE write to 0xb00 precede or follow the stale ZERO fill? does the write hit the stale line?).
  // bit24 = core_we (0=read-serve, 1=write); [31:28]=serve {rd_match,hit_way,hit1,hit0}; [23:0]=addr.
  // build #25 (ENTRY-REGION load-vs-store localization): capture copy#1's READS of src 0x980-0x9ff (the
  // FreeDOS entry code ~0x9af that maps to dst 0x2af) AND its WRITES to dst 0x80280-0x802ff (the derail
  // point 0x802af). Freeze at cs=0070:0x27f (after the copies, before the RETF/part-B reload). Then the
  // ring shows, for the EXACT failing byte: what the LOAD served (rdata+serve hit-state) vs what the STORE
  // wrote (wdata) -> proves whether the LOAD serves stale data (L1D read bug) or the STORE writes wrong
  // data (store path). [31:28]=serve{rd_match,hit_way,hit1,hit0} [24]=we [23:0]=addr; data=wdata/rdata.
  // build #26 (LOAD-vs-STORE at the FIRST copy byte, no string-loop noise): copy#1's read of src
  // 0x700-0x707 (LOAD) + write of dst 0x80000-0x80007 (STORE). ONLY copy#1 touches these (copy#2 starts
  // at dst 0x8000a, copy#3 at 0x80077, the string loop reads src 0x980+, disk writes are we=1 to 0x700).
  // rdata at 0x700 = what the LOAD served; wdata at 0x80000 = what the STORE wrote. If load=4d5a (=DDR)
  // and store=4d5a but DDR[0x80000]=5589e5 -> WRITES LOST (dst retains pre-existing). If store=5589e5 ->
  // store-data corrupt. [31:28]=serve{rd_match,hit_way,hit1,hit0} [24]=we [23:0]=addr; data=wdata/rdata.
  // build #27 (HP0-side LOCALIZATION): route the ring to ven_axi_master's FILL tap (m_axi_rdata = the
  // word ven_l1d's fill RECEIVES from downstream). Filter to SET 0x38 = the 0x700 source line (low bits,
  // REMAP-independent; the string loop's 0x980 is set 0x4c, filtered out). If the FILL of 0x700 returns
  // WIN9/QUAK -> corruption is DOWNSTREAM of ven_axi_master (axi2avalon/L2/DDRAM/HP0 read path). If it
  // returns MZ (correct) -> the corruption is IN ven_l1d (fill array write vs serve). addr=remapped DDR
  // beat addr (low 24b = x86); data = raw AXI R word.
  // build #30: CORE-SIDE load/store tap, paired with the store-address freeze on the FIRST dest write to
  // 0x80000 (pl.v d_wr_freeze). Captures the copy's FIRST-byte read of src 0x700-0x707 (LOAD data+serve)
  // and write of dst 0x80000-0x80007 (STORE data) at the copy START (not evicted). Resolves store-vs-load:
  // load(0x700)=MZ & store(0x80000)=MZ -> faithful (bug elsewhere); load=MZ store=5589e5 -> store-data
  // corrupt; load=5589e5 -> the load reads the WRONG address (src not 0x700). (void axm_dbg_* to avoid
  // unused-net synth churn.)
  // build #32: capture EVERY core transaction (read+write, no addr filter) frozen on the copy's FIRST
  // store to 0x80000 (pl.v d_wr_freeze). The ring then holds the copy's FIRST loads with their ACTUAL
  // addresses -> reveals whether the copy load reads 0x700 (src, correct addr) or a WRONG address X
  // (deterministic address bug). [31:28]=serve [24]=we [23:0]=addr; data=wdata/rdata.
  // MINI-ILA (S_FETCH-wedge forensics): EVERY-CYCLE rolling sample of the core mem-port + L1D backing
  // handshake. The dbg ring (frozen at tracesecs) then holds the last 128 dbg-clk cycles BEFORE the freeze —
  // a waveform of the wedge steady state: core_req=1/core_ack=0 with L1D st/rd_match shows exactly WHO is
  // refusing to serve (L1D stuck non-IDLE, rd_match=0 forever, backing m_req lost, etc.).
  //   addr = live core_addr; data[31:0] = {8'd0, l1d_dbg_serve[7:0],
  //          2'd0, core_req, core_we, core_ack, m_req, m_we, m_ack, 8'd0}
  // VGA-TEXT TAP (screen visibility): the guest's VGA text-mode writes (`mov [0xB8xxx],ax`) pass through
  // this core port on their way to vga.v (avalon slave) — capture WRITES to the 0xB8000-0xB8FFF text page
  // into the dbg ring. Frozen at tracesecs, the 128-deep ring holds the LAST 128 characters drawn to the
  // screen = the prompt / message the guest printed right before its input wait. The daemon reconstructs
  // (addr-0xB8000)/2 -> column/row, low byte of data -> ASCII char. Removes the VGA-BRAM blind spot.
  assign dbg_rd_valid = core_req & core_we & core_ack & (core_addr[23:12] == 12'h0B8);
  assign dbg_rd_addr  = core_addr;
  assign dbg_rd_data  = core_wdata;
  wire _unused_core_dbg = &{1'b0, core_rdata, l1d_dbg_serve, m_req, m_we, m_ack, axm_dbg_rv, axm_dbg_ra, axm_dbg_rd};
`endif

endmodule : ventium_l1_axi
