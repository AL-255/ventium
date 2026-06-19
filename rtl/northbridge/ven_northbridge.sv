// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// northbridge/ven_northbridge.sv — the 430FX "Triton" TSC system-controller core
// (Phase C, docs/northbridge-system-spec.md §4-5): the cache+route layer that sits on
// the L1's backing seam. It wraps:
//   * ven_cachemap — the per-access cacheability decision (PAM/TOM/CC/holes/SMRAM);
//   * ven_l2       — the write-back UltraRAM L2 (only CACHEABLE traffic flows through it);
//   * a BYPASS router — UNCACHEABLE accesses skip the L2 entirely and go straight to the
//     downstream backing port (so MMIO / non-cacheable DRAM never pollutes or stales the L2).
//
//   ven_l1d.m_*  ─►  [u_*] ven_northbridge [d_*]  ─►  ven_axi_master  ─►  AXI4 → DDR
//                         │
//                         ├─ cacheable  → ven_l2 → d_*
//                         └─ uncacheable → (bypass) → d_*
//
// It presents the SAME word-granular backing protocol as ven_l2 on BOTH ports, so it is a
// drop-in for the bare-ven_l2 slot in ventium_l1_axi (the upstream master — ven_l1d — and
// the downstream slave — ven_axi_master/CDC — are unchanged).
//
// SINGLE-OUTSTANDING: the upstream (ven_l1d) is blocking, so exactly one transaction is in
// flight; `route` (cacheable?) is derived combinationally from the stable u_addr and holds
// for the whole transaction (a 32 B line never straddles a cacheability region, which are
// ≥16 KiB aligned), so the steering mux is glitch-free without latching.
//
// CONFIG (cfg_*): the TSC cacheability registers live in PCI config space (bus0:dev0); Phase
// D wires the PCI-config shim to them. Until then ventium_l1_axi drives bootable constants
// (FLCE=1, SCS populated, all DRAM below TOM cacheable). is_code is tied 0 here — this is the
// DATA/unified backing path; instruction-fetch KEN# is handled at the icache (spine-resident).
//
// NOTE (Phase C scope): both the cacheable and the bypass paths share ONE downstream (DDR via
// ven_axi_master). The cachemap `to_dram` (DRAM vs forward-to-PCI/MMIO) does NOT yet split the
// downstream — a separate MMIO master to the southbridge + single-beat MMIO granularity land in
// Phase D. For now "bypass" means "around the L2, straight to DDR", which is correct for the
// DRAM-backed uncacheable regions (BIOS shadow, the memory hole) and keeps the L2 unpolluted.

module ven_northbridge #(
    parameter int L2_CAP_BYTES = 2*1024*1024,   // L2 data capacity (default → all 64 URAM)
    parameter int L2_LINE      = 32,            // bytes/line (== L1 fill granularity)
    parameter int L2_WAYS      = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        ready,                  // 1 once the L2 init valid-clear walk is done

    // ---- TSC cacheability config (PCI cfg bus0:dev0; constants until Phase D) ---
    input  logic [55:0] cfg_pam,                // {PAM6..PAM0}
    input  logic [7:0]  cfg_dramc,              // DRAM Control (HEN)
    input  logic [7:0]  cfg_cc,                 // Cache Control (FLCE/SCFMI/SCS)
    input  logic [7:0]  cfg_tom_mb4,            // top of memory, 4-MiB units
    input  logic [7:0]  cfg_smram,              // SMRAM control
    input  logic        smm_active,             // CPU in SMM (gates the SMRAM aperture)

    // ---- UPSTREAM backing SLAVE (from ven_l1d.m_*) ----------------------------
    input  logic        u_req,
    input  logic        u_we,
    input  logic [31:0] u_addr,
    input  logic [31:0] u_wdata,
    input  logic [3:0]  u_wstrb,
    output logic [31:0] u_rdata,
    output logic        u_ack,

    // ---- DOWNSTREAM backing MASTER (to ven_axi_master / CDC → DDR) --------------
    output logic        d_req,
    output logic        d_we,
    output logic [31:0] d_addr,
    output logic [31:0] d_wdata,
    output logic [3:0]  d_wstrb,
    input  logic [31:0] d_rdata,
    input  logic        d_ack
`ifdef VEN_DBG_CORE
    ,
    output logic [31:0] dbg_hits,        // L2 hits
    output logic [31:0] dbg_misses,      // L2 misses
    output logic [31:0] dbg_wbacks,      // L2 dirty write-backs
    output logic [31:0] dbg_bypass       // uncacheable transactions routed around the L2
`endif
);

  // ---- cacheability decision for THIS transaction ---------------------------
  logic        to_dram, l1_cacheable, l2_cacheable;
  logic [3:0]  cm_region;
  ven_cachemap u_cmap (
      .addr(u_addr), .is_write(u_we), .is_code(1'b0), .smm_active(smm_active),
      .pam(cfg_pam), .dramc(cfg_dramc), .cc(cfg_cc), .tom_mb4(cfg_tom_mb4), .smram(cfg_smram),
      .to_dram(to_dram), .l1_cacheable(l1_cacheable), .l2_cacheable(l2_cacheable),
      .region(cm_region));

  // route=1 → through the L2 (write-back cacheable); route=0 → bypass straight to DDR.
  logic route;
  assign route = l2_cacheable;

  // ---- L2 instance (only sees CACHEABLE traffic) ----------------------------
  logic        l2_u_ack;  logic [31:0] l2_u_rdata;
  logic        l2_d_req, l2_d_we; logic [31:0] l2_d_addr, l2_d_wdata; logic [3:0] l2_d_wstrb;
  ven_l2 #(.L2_CAP_BYTES(L2_CAP_BYTES), .L2_LINE(L2_LINE), .L2_WAYS(L2_WAYS)) u_l2 (
      .clk(clk), .rst_n(rst_n), .ready(ready),
      .u_req(route & u_req), .u_we(u_we), .u_addr(u_addr), .u_wdata(u_wdata), .u_wstrb(u_wstrb),
      .u_rdata(l2_u_rdata), .u_ack(l2_u_ack),
      .d_req(l2_d_req), .d_we(l2_d_we), .d_addr(l2_d_addr), .d_wdata(l2_d_wdata), .d_wstrb(l2_d_wstrb),
      .d_rdata(d_rdata), .d_ack(route ? d_ack : 1'b0)     // L2 only sees acks on its own (cacheable) txns
`ifdef VEN_DBG_CORE
      , .dbg_hits(dbg_hits), .dbg_misses(dbg_misses), .dbg_wbacks(dbg_wbacks)
`endif
  );

  // ---- downstream mux: L2's master when routing through it, else the raw upstream
  // request (the bypass — a straight pass-through to DDR). ---------------------
  assign d_req   = route ? l2_d_req   : u_req;
  assign d_we    = route ? l2_d_we    : u_we;
  assign d_addr  = route ? l2_d_addr  : u_addr;
  assign d_wdata = route ? l2_d_wdata : u_wdata;
  assign d_wstrb = route ? l2_d_wstrb : u_wstrb;

  // ---- upstream response: from the L2 on a cacheable txn, else straight from DDR.
  assign u_rdata = route ? l2_u_rdata : d_rdata;
  assign u_ack   = route ? l2_u_ack   : d_ack;

`ifdef VEN_DBG_CORE
  // count uncacheable (bypass) transactions: one per completed bypass ack.
  always_ff @(posedge clk) begin
    if (!rst_n) dbg_bypass <= '0;
    else if (!route && u_req && u_ack) dbg_bypass <= dbg_bypass + 32'd1;
  end
`endif

endmodule : ven_northbridge
