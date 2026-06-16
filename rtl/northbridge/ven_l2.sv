// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// northbridge/ven_l2.sv — UltraRAM-backed L2 cache controller (STANDALONE, not yet wired).
//
// PURPOSE.  The KV260 part (xck26-sfvc784) carries 64 UltraRAM blocks (URAM288:
// 4096 deep x 72 bits = 288 Kb each → 18 Mb total) that the core/L1 leave idle.
// This module turns all 64 of them into a large, set-associative, WRITE-BACK L2
// that sits between the L1's word-granular backing port and the PS-DDR AXI master,
// HIDING the long DDR4 round-trip behind (a) a multi-megabyte on-chip working set
// (most L1 misses now hit in L2, no DDR access at all), (b) an on-chip L2-hit
// latency of a handful of cycles vs ~50–100 for DDR, and (c) write-back absorption
// of the L1's write-through store stream (a dirty line is written to DDR once on
// eviction, not on every store).
//
// WHERE IT FITS (the whole point of the port shapes below).  The subsystem already
// speaks a single WORD-GRANULAR "backing port" protocol that ven_l1d DRIVES and
// ven_axi_master CONSUMES (see mem/ven_axi_master.sv header):
//     core mem_* ─► ven_l1d ─(backing port)─► ven_axi_master ─► AXI4 ─► PS-DDR
// This L2 is a DROP-IN for that wire: it presents the SAME backing protocol as a
// SLAVE on its upstream (u_*) port (so ven_l1d's master plugs straight in) and
// DRIVES the SAME backing protocol as a MASTER on its downstream (d_*) port (so
// ven_axi_master's slave plugs straight in):
//     ven_l1d.m_* ─► [u_*] ven_l2 [d_*] ─► ven_axi_master.m_*
// Integrating it later is therefore a pure rewire — NO change to ven_l1d or
// ven_axi_master. Per the task, this file is standalone + unit-checkable; nothing
// in the core/SoC instantiates it yet.
//
// BACKING-PORT CONTRACT (must match ven_l1d ⇄ ven_axi_master EXACTLY).
//   * READ (a line fill): the requester holds *_req=1, *_we=0 and walks WORDS=8
//     sequential, line-aligned word addresses; it expects ONE *_ack (+ *_rdata) per
//     word, in ascending order, with NO per-beat valid and NO backpressure (the
//     requester advances its fill counter on every clock where *_ack=1). The base is
//     latched from the FIRST presented address ([..:OFF_W]); the changing low bits
//     are ignored. ven_l1d only ever reads a full 32-byte line, so every read here
//     is exactly WORDS words. (mem/ven_axi_master.sv:6-18, ven_l1d.sv:163-177.)
//   * WRITE (write-through from L1): one transaction, *_we=1, a BYTE address +
//     lane-0-based *_wstrb (4 strobes covering bytes [addr[4:0] .. addr[4:0]+3]).
//     The store may straddle a 32-bit word AND the 32-byte line end. Exactly ONE
//     *_ack when the store is durable. (ven_l1d.sv writes c_wstrb verbatim; the
//     downstream master used to split it — here the L2 splits it across lines, below.)
//   * single outstanding: the L1's mem port is single-beat and its fill is blocking,
//     so the L2 only ever sees ONE upstream transaction at a time. That is why this
//     L2 needs NO MSHR / hit-under-miss — the latency hiding is capacity + fast hits
//     + write-back, not request-level parallelism. (Hit-under-miss only matters with
//     independent I/D requesters → an integration-time arbiter concern, see §FOLLOW-ON.)
//
// MICROARCHITECTURE.
//   * Geometry (defaults): 2 MiB, 32-byte line (= the L1 fill granularity == the
//     oracle p5trace line, so behaviour stays consistent), L2_WAYS-way set assoc.
//     2 MiB / 32 B = 65536 lines = a 65536-deep x 256-bit DATA RAM, which Vivado
//     tiles as 4 URAM-wide (4×64=256 data bits; each URAM288 word is 72b, so the four
//     tiles leave 4×8 = 32 spare parity bits/word — ample for a future SECDED(265,256),
//     which needs 9 check bits) × 16 URAM-deep cascade = EXACTLY 64 URAM288 blocks. Tags +
//     {valid,dirty} + tree-PLRU live in one packed-per-set BRAM (~1.1 Mb).
//   * Policy: WRITE-BACK + WRITE-ALLOCATE. A store hit RMWs the resident line and
//     marks it dirty (no DDR); a store miss fills the line then merges (no DDR write
//     until eviction). A clean victim is dropped; a dirty victim is written back to
//     DDR (8 word writes) before its slot is refilled.
//   * Hit path: serial TAG → DATA (read the indexed set's tags, compare, then read
//     the selected way's 256-bit line). On-chip, a few cycles. A read hit streams the
//     8 words upstream; a write hit byte-writes the store into the line in place.
//   * Read-miss path: FORWARD-DURING-FILL — every word returned by DDR is handed
//     straight to the L1 (u_ack=d_ack, u_rdata=d_rdata) AS IT ARRIVES and also
//     captured into the line buffer, so the L2 adds ≈0 latency over a bare DDR fill
//     while still populating itself for the next time.
//   * Replacement: tree-PLRU, but an INVALID way is always preferred (fill cold
//     capacity before evicting anything).
//   * INIT: BRAM/URAM have no global reset, so after reset an init FSM walks all sets
//     clearing valid bits (L2_SETS clocks); `ready` deasserts until done. Upstream
//     requests are ignored (not acked) during init.
//
// FOLLOW-ON (intentionally NOT in this first standalone drop, noted so reviewers
// don't read their absence as a bug): SECDED ECC over the 32 spare URAM parity bits; a
// writeback BUFFER so a dirty eviction doesn't serialize in front of the fill; burst
// (vs per-word) dirty writeback; a next-line/stride PREFETCHER (needs a low-priority
// abortable channel, which needs the integration-time I/D arbiter); a proper
// writeback-FLUSH walker for cosim coherence (a bulk invalidate would DROP dirty
// data, so flush is deliberately omitted rather than done wrong); MSHR/hit-under-miss
// once there are multiple requesters. None affect the correctness of what is here.

module ven_l2 #(
    parameter int L2_CAP_BYTES = 2*1024*1024,  // total data capacity (→ 64 URAM at default)
    parameter int L2_LINE      = 32,           // bytes/line (== L1 fill granularity)
    parameter int L2_WAYS      = 8,            // set-associativity (power of 2)
    // DATA URAM read latency. A DEEP URAM cascade must be pipelined: Vivado/xpm spread
    // ~one cascade-output register per few tiles, so a 16-tile-deep column (the default
    // 2 MiB config: 65536/4096 = 16 deep) needs several register stages, not just the
    // 2 that register a shallow array's output. So default scales with cascade depth:
    // ≥4 tiles deep → 5 (covers the 16-deep default with margin), else the 2-cycle
    // minimum (URAM output reg + 1). The FSM is fully data_valid-driven so a larger
    // latency is functionally free (a few more on-chip cycles, still << DDR). Confirm
    // URAM288=64 AND timing with fpga/scripts/probe_l2_uram.tcl.
    parameter int RAM_RD_LAT   = (((L2_CAP_BYTES/L2_LINE)+4095)/4096 >= 4) ? 5 : 2
) (
    input  logic        clk,
    input  logic        rst_n,

    output logic        ready,    // 0 during the post-reset valid-clear walk; 1 = serving

    // ---- UPSTREAM backing SLAVE port (toward L1 / ven_l1d's m_* master) --------
    // Mirrors what ven_axi_master exposes to ven_l1d: u_req/we/addr/wdata/wstrb in,
    // u_rdata/u_ack out. Drop-in for ven_l1d.m_* ↔ here.
    input  logic        u_req,
    input  logic        u_we,
    input  logic [31:0] u_addr,
    input  logic [31:0] u_wdata,
    input  logic [3:0]  u_wstrb,
    output logic [31:0] u_rdata,
    output logic        u_ack,

    // ---- DOWNSTREAM backing MASTER port (toward PS-DDR / ven_axi_master's slave) -
    // Drives the SAME protocol ven_l1d drives, so ven_axi_master.m_* plugs straight
    // in: d_req/we/addr/wdata/wstrb out, d_rdata/d_ack in. The 32-bit physical
    // address is forwarded verbatim; ven_axi_master does the 32→40-bit DDR remap.
    output logic        d_req,
    output logic        d_we,
    output logic [31:0] d_addr,
    output logic [31:0] d_wdata,
    output logic [3:0]  d_wstrb,
    input  logic [31:0] d_rdata,
    input  logic        d_ack

    // NOTE on a STUCK downstream (DDR/bridge never returns d_ack): the L2 deliberately
    // has NO internal watchdog. A bus fault is handled OUT-OF-BAND — ven_axi_master
    // (the downstream master) raises its own sticky `bus_err`, which the integration
    // wires straight to the core's bus_err→S_HALT override (it is NOT part of the
    // backing-port wire the L2 splices into). That halts the core and the PS resets the
    // whole PL, so the L2 wedging in S_FILL/S_WB is moot — it is torn down by the reset,
    // not by unwinding its own FSM. (A self-contained L2 watchdog + fault re-export is a
    // possible hardening once the L2 is actually wired; intentionally out of scope here.)

`ifdef VEN_DBG_CORE
    ,
    // ---- opt-in observability (matches the repo's VEN_DBG_CORE convention) ------
    output logic [31:0] dbg_hits,        // upstream transactions that hit
    output logic [31:0] dbg_misses,      // upstream transactions that missed
    output logic [31:0] dbg_wbacks       // dirty lines written back to DDR
`endif
);

  // ---- derived geometry ------------------------------------------------------
  localparam int LW       = L2_LINE*8;             // line bits (256)
  localparam int WORDS    = L2_LINE/4;             // words/line (8)
  localparam int NBE      = L2_LINE;               // byte-enable width (32)
  localparam int L2_LINES = L2_CAP_BYTES/L2_LINE;  // total lines (65536)
  localparam int L2_SETS  = L2_LINES/L2_WAYS;      // sets (8192)
  localparam int OFF_W    = $clog2(L2_LINE);       // line-offset bits (5)
  localparam int IDX_W    = $clog2(L2_SETS);       // set-index bits (13)
  localparam int TAG_W    = 32-OFF_W-IDX_W;        // tag bits (14)
  localparam int WAY_W    = (L2_WAYS<=1) ? 1 : $clog2(L2_WAYS);  // way-index bits (3)
  localparam int LIDX_W   = IDX_W+WAY_W;           // data-line index = {set,way} (16)
  localparam int TE_W     = TAG_W+2;               // per-way tag entry {valid,dirty,tag}
  localparam int PLRU_W   = L2_WAYS-1;             // tree-PLRU bits/set (7)
  localparam int META_W   = L2_WAYS*TE_W+PLRU_W;   // packed per-set meta word (135)

`ifndef SYNTHESIS
  initial begin
    if ((L2_WAYS & (L2_WAYS-1)) != 0)
      $fatal(1, "ven_l2: L2_WAYS must be a power of 2 (tree-PLRU)");
    if (L2_LINE != 32)
      $fatal(1, "ven_l2: L2_LINE must be 32 (backing fill is WORDS=8 words)");
    if (L2_CAP_BYTES % (L2_LINE*L2_WAYS) != 0)
      $fatal(1, "ven_l2: L2_CAP_BYTES must be a multiple of L2_LINE*L2_WAYS");
    if (RAM_RD_LAT < 2)
      $fatal(1, "ven_l2: RAM_RD_LAT must be >= 2 (a cascaded URAM needs the output reg)");
  end
`endif

  // ===========================================================================
  // helper functions
  // ===========================================================================
  // tree-PLRU victim: descend the WAY_W-level tree, taking the side each node bit
  // points at (the LRU side). Node indices are 1-based (heap); plru[node-1] is the
  // node bit; leaves are nodes [L2_WAYS .. 2*L2_WAYS-1] → way = node-L2_WAYS.
  function automatic logic [WAY_W-1:0] plru_victim(input logic [PLRU_W-1:0] p);
    int node;
    node = 1;
    for (int lvl=0; lvl<WAY_W; lvl++)
      node = (node<<1) | (p[node-1] ? 1 : 0);
    plru_victim = WAY_W'(node - L2_WAYS);
  endfunction

  // tree-PLRU touch: along the path to `w`, set each node bit to point AWAY from w
  // (making w most-recently-used).
  function automatic logic [PLRU_W-1:0] plru_touch(input logic [PLRU_W-1:0] p,
                                                   input logic [WAY_W-1:0] w);
    int node; logic side;
    plru_touch = p;
    node = 1;
    for (int lvl=0; lvl<WAY_W; lvl++) begin
      side = w[WAY_W-1-lvl];
      plru_touch[node-1] = ~side;
      node = (node<<1) | (side ? 1 : 0);
    end
  endfunction

  // assemble a packed per-set meta word: take `base`, overwrite way `w`'s entry with
  // {valid,dirty,tag}, and set the PLRU field.
  function automatic logic [META_W-1:0] meta_set(input logic [META_W-1:0] base,
                                                 input logic [WAY_W-1:0]  w,
                                                 input logic              v,
                                                 input logic              d,
                                                 input logic [TAG_W-1:0]  t,
                                                 input logic [PLRU_W-1:0] pl);
    meta_set = base;
    meta_set[w*TE_W +: TE_W]      = {v, d, t};
    meta_set[L2_WAYS*TE_W +: PLRU_W] = pl;
  endfunction

  // byte-merge: overwrite the strobed bytes of `base` with `wd`.
  function automatic logic [LW-1:0] merge_line(input logic [LW-1:0]  base,
                                               input logic [NBE-1:0] be,
                                               input logic [LW-1:0]  wd);
    merge_line = base;
    for (int b=0; b<NBE; b++)
      if (be[b]) merge_line[b*8 +: 8] = wd[b*8 +: 8];
  endfunction

  // ===========================================================================
  // arrays
  // ===========================================================================
  // DATA: the UltraRAM. 65536 × 256b at default → 64 URAM288 (4 wide × 16 deep). SDP:
  // one synchronous write port (byte-enabled, for fills + in-place store merges) and
  // one synchronous read port (RAM_RD_LAT-deep pipeline for the deep cascade). The
  // FSM never reads and writes the data array in the same cycle.
  (* ram_style = "ultra", cascade_height = 16 *)
  logic [LW-1:0] l2_data [L2_LINES];

  // META: tags + {valid,dirty} (all ways) + tree-PLRU, packed one word per set, in
  // BRAM. Registered read (1 cycle). Updated by RMW (single-outstanding → no hazard).
  (* ram_style = "block" *)
  logic [META_W-1:0] l2_meta [L2_SETS];

  // ---- DATA read port: RAM_RD_LAT-stage pipeline + a valid shift register --------
  logic [LIDX_W-1:0] dra;              // data read address (driven combinationally)
  logic              dgo;             // launch a data read this cycle
  logic [LW-1:0]     dpipe [RAM_RD_LAT];
  logic [RAM_RD_LAT-1:0] dvld_sr;
  always_ff @(posedge clk) begin
    dpipe[0] <= l2_data[dra];
    for (int i=1; i<RAM_RD_LAT; i++) dpipe[i] <= dpipe[i-1];
    if (!rst_n) dvld_sr <= '0;
    else        dvld_sr <= (RAM_RD_LAT==1) ? RAM_RD_LAT'(dgo)
                                           : {dvld_sr[RAM_RD_LAT-2:0], dgo};
  end
  wire              data_valid = dvld_sr[RAM_RD_LAT-1];
  wire [LW-1:0]     data_out   = dpipe[RAM_RD_LAT-1];

  // ---- DATA write port: byte-enabled SDP write -------------------------------
  logic [LIDX_W-1:0] dwa;             // data write address
  logic              dwe;             // data write enable
  logic [NBE-1:0]    dwbe;            // per-byte write enable
  logic [LW-1:0]     dwd;             // write data
  always_ff @(posedge clk)
    if (dwe)
      for (int b=0; b<NBE; b++)
        if (dwbe[b]) l2_data[dwa][b*8 +: 8] <= dwd[b*8 +: 8];

  // ---- META read/write port --------------------------------------------------
  logic [IDX_W-1:0]  mra;             // meta read address (registered set index)
  logic [META_W-1:0] meta_q;          // registered meta read
  logic              mwe;             // meta write enable
  logic [IDX_W-1:0]  mwa;             // meta write address
  logic [META_W-1:0] mwd;             // meta write data
  always_ff @(posedge clk) begin
    if (mwe) l2_meta[mwa] <= mwd;
    meta_q <= l2_meta[mra];
  end

  // ===========================================================================
  // combinational decode of the current set (valid from S_LK1 onward)
  // ===========================================================================
  // current transaction's line decode (cur_addr is the active phase's line address)
  logic [31:0]       cur_addr;
  wire  [IDX_W-1:0]  cur_set  = cur_addr[OFF_W +: IDX_W];
  wire  [TAG_W-1:0]  cur_tag  = cur_addr[OFF_W+IDX_W +: TAG_W];
  wire  [31:0]       cur_base = {cur_addr[31:OFF_W], {OFF_W{1'b0}}};

  logic [L2_WAYS-1:0] dec_v, dec_d, hitvec, invvec;
  logic [TAG_W-1:0]   dec_tag [L2_WAYS];
  logic [PLRU_W-1:0]  dec_plru;
  logic               hit, inv_exists;
  logic [WAY_W-1:0]   hit_way, inv_way, vic_way;
  logic               vic_dirty;
  logic [TAG_W-1:0]   vic_tag;
  always_comb begin
    dec_plru = meta_q[L2_WAYS*TE_W +: PLRU_W];
    for (int w=0; w<L2_WAYS; w++) begin
      dec_tag[w] = meta_q[w*TE_W +: TAG_W];
      dec_d[w]   = meta_q[w*TE_W+TAG_W];
      dec_v[w]   = meta_q[w*TE_W+TAG_W+1];
      hitvec[w]  = dec_v[w] && (dec_tag[w] == cur_tag);
      invvec[w]  = ~dec_v[w];
    end
    hit        = |hitvec;
    inv_exists = |invvec;
    // priority-encode hit way and lowest invalid way
    hit_way = '0; inv_way = '0;
    for (int w=L2_WAYS-1; w>=0; w--) begin
      if (hitvec[w]) hit_way = WAY_W'(w);
      if (invvec[w]) inv_way = WAY_W'(w);
    end
    vic_way   = inv_exists ? inv_way : plru_victim(dec_plru);
    vic_dirty = !inv_exists && dec_v[vic_way] && dec_d[vic_way];
    vic_tag   = dec_tag[vic_way];
  end

  // ===========================================================================
  // FSM
  // ===========================================================================
  typedef enum logic [3:0] {
    S_INIT,        // walk sets clearing valid bits
    S_IDLE,        // wait for an upstream request
    S_LK0,         // meta read launched; 1-cycle wait
    S_LK1,         // meta_q valid → decode + branch (and commit hit-path writes)
    S_RHIT_WAIT,   // read hit: wait for the data-array read
    S_STREAM,      // read hit: stream WORDS words upstream
    S_EV_WAIT,     // dirty miss: wait for the victim line read
    S_WB,          // write the victim line back to DDR (WORDS word writes)
    S_FILL,        // fetch the line from DDR (WORDS word reads; forward up if read)
    S_MERGE,       // commit the filled line (+merge store) to URAM + meta
    S_WDONE,       // write transaction: advance to phase 1 (line straddle) or ack
    S_WACK         // write transaction: one-cycle upstream ack
  } state_e;
  state_e state;

  logic [IDX_W:0]    init_cnt;        // init valid-clear walk counter
  logic              cur_we;          // current transaction is a write
  logic              req_armed;       // u_req has gone low since the last accept (single-outstanding)
  logic [3:0]        sw;              // upstream stream word counter
  logic [3:0]        dw;              // downstream word counter (fill / writeback)
  logic [LW-1:0]     line_buf;        // read-hit line (for streaming)
  logic [LW-1:0]     wb_buf;          // victim line (for writeback)
  logic [LW-1:0]     fill_buf;        // line being filled from DDR
  logic [31:0]       wb_base;         // victim line's DDR base address
  logic [WAY_W-1:0]  sel_way;         // way being filled (victim) — latched in S_LK1
  logic [PLRU_W-1:0] plru_lat;        // latched PLRU (for the commit MRU update)

  // write-store decomposition: a byte store maps onto line L (be0/wd0) and, if it
  // spills past the 32-byte line end, the next line L+1 (be1/wd1, low 3 bytes only).
  logic [NBE-1:0]    be0, be1;
  logic [LW-1:0]     wd0, wd1;
  logic              need_l1;         // store touches a second line
  logic              phase;           // 0 = line L, 1 = line L+1
  logic [31:0]       p1base;          // line L+1 base address
  logic [NBE-1:0]    wbe;             // active phase byte-enable (be0 or be1)
  logic [LW-1:0]     wwd;             // active phase write data (wd0 or wd1)

  // ---- store decomposition for the request currently at the upstream port ------
  logic [NBE-1:0]    nbe0, nbe1;
  logic [LW-1:0]     nwd0, nwd1;
  logic              nneed_l0, nneed_l1;
  always_comb begin
    nbe0 = '0; nbe1 = '0; nwd0 = '0; nwd1 = '0;
    for (int b=0; b<4; b++) begin
      // byte b of the store lands at line-byte (u_addr[4:0] + b); bytes ≥ 32 spill
      // into the next line at (that − 32). u_addr[4:0]+b ≤ 34, so spill ≤ byte 2.
      automatic int idx = int'(u_addr[OFF_W-1:0]) + b;
      if (u_wstrb[b]) begin
        if (idx < L2_LINE) begin nbe0[idx]        = 1'b1; nwd0[idx*8 +: 8]        = u_wdata[b*8 +: 8]; end
        else             begin nbe1[idx-L2_LINE]  = 1'b1; nwd1[(idx-L2_LINE)*8 +: 8] = u_wdata[b*8 +: 8]; end
      end
    end
    nneed_l0 = |nbe0;     // line L actually has strobed bytes
    nneed_l1 = |nbe1;     // the store spills into line L+1
  end

  // ===========================================================================
  // data-array READ launch (combinational): read-hit line, or dirty-victim line
  // ===========================================================================
  always_comb begin
    dgo = 1'b0;
    dra = '0;
    if (state == S_LK1) begin
      if (!cur_we && hit)            begin dgo = 1'b1; dra = {cur_set, hit_way}; end  // read hit
      else if (!hit && vic_dirty)    begin dgo = 1'b1; dra = {cur_set, vic_way}; end  // dirty victim
    end
  end

  // ===========================================================================
  // meta + data WRITE drive (combinational; the clocked RAM ports above commit them)
  // ===========================================================================
  always_comb begin
    mwe = 1'b0; mwa = cur_set; mwd = meta_q;
    dwe = 1'b0; dwa = {cur_set, sel_way}; dwbe = '0; dwd = '0;
    unique case (state)
      S_INIT: begin
        mwe = 1'b1; mwa = init_cnt[IDX_W-1:0]; mwd = '0;   // clear valid (whole word 0)
      end
      S_LK1: begin
        if (cur_we && hit) begin
          // write HIT: byte-write the store into the resident line + set dirty + MRU.
          dwe = 1'b1; dwa = {cur_set, hit_way}; dwbe = wbe; dwd = wwd;
          mwe = 1'b1; mwa = cur_set;
          mwd = meta_set(meta_q, hit_way, 1'b1, 1'b1, cur_tag, plru_touch(dec_plru, hit_way));
        end else if (!cur_we && hit) begin
          // read HIT: PLRU MRU touch only (keep valid/dirty/tag).
          mwe = 1'b1; mwa = cur_set;
          mwd = meta_set(meta_q, hit_way, 1'b1, dec_d[hit_way], dec_tag[hit_way],
                         plru_touch(dec_plru, hit_way));
        end
      end
      S_MERGE: begin
        // commit the filled line into the victim way (+merge the store if a write),
        // then tag it valid, dirty iff this was a write, MRU.
        dwe = 1'b1; dwa = {cur_set, sel_way}; dwbe = '1;
        dwd = cur_we ? merge_line(fill_buf, wbe, wwd) : fill_buf;
        mwe = 1'b1; mwa = cur_set;
        mwd = meta_set(meta_q, sel_way, 1'b1, cur_we, cur_tag, plru_touch(plru_lat, sel_way));
      end
      default: ;
    endcase
  end

  // ===========================================================================
  // backing-port OUTPUT drive (combinational)
  // ===========================================================================
  always_comb begin
    u_ack = 1'b0; u_rdata = 32'd0;
    d_req = 1'b0; d_we = 1'b0; d_addr = 32'd0; d_wdata = 32'd0; d_wstrb = 4'd0;
    unique case (state)
      S_STREAM: begin
        u_ack   = (sw < WORDS[3:0]);
        u_rdata = line_buf[sw*32 +: 32];
      end
      S_FILL: begin
        d_req  = 1'b1; d_we = 1'b0;
        d_addr = cur_base + {26'd0, dw, 2'b00};
        if (!cur_we) begin u_ack = d_ack; u_rdata = d_rdata; end  // forward-during-fill
      end
      S_WB: begin
        d_req   = 1'b1; d_we = 1'b1;
        d_addr  = wb_base + {26'd0, dw, 2'b00};
        d_wdata = wb_buf[dw*32 +: 32];
        d_wstrb = 4'hF;
      end
      S_WACK: u_ack = 1'b1;
      default: ;
    endcase
  end

  // ===========================================================================
  // FSM sequencing
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_INIT; init_cnt <= '0; ready <= 1'b0;
      sw <= '0; dw <= '0; phase <= 1'b0; cur_we <= 1'b0; req_armed <= 1'b1;
    end else begin
      if (!u_req) req_armed <= 1'b1;   // upstream released the port → re-arm acceptance
      unique case (state)
        // ---- post-reset valid-clear walk (meta write driven combinationally) -
        S_INIT: begin
          if (init_cnt == (IDX_W+1)'(L2_SETS-1)) begin
            ready <= 1'b1; state <= S_IDLE;
          end else init_cnt <= init_cnt + (IDX_W+1)'(1);
        end

        // ---- accept a new upstream transaction -----------------------------
        // single-outstanding: req_armed requires u_req to have gone LOW since the last
        // accept, so a request HELD high past its ack is never re-executed (ven_l1d
        // always drops m_req between backing transactions — read fill ends in L1_DONE,
        // a write drops on c_ack — so this never delays the intended upstream).
        S_IDLE: begin
          if (u_req && req_armed) begin
            automatic logic [31:0] l1b = {u_addr[31:OFF_W], {OFF_W{1'b0}}} + 32'(L2_LINE);
            req_armed <= 1'b0;                  // consume — re-arm only on a u_req low
            cur_we   <= u_we;
            be0 <= nbe0; wd0 <= nwd0; be1 <= nbe1; wd1 <= nwd1; need_l1 <= nneed_l1;
            p1base   <= l1b;
            if (!u_we || nneed_l0) begin
              // READ, or WRITE whose line L has strobed bytes → start at phase 0 (line L).
              cur_addr <= u_addr;  phase <= 1'b0;
              wbe      <= nbe0;     wwd   <= nwd0;
              mra      <= u_addr[OFF_W +: IDX_W];
              state    <= S_LK0;
            end else if (nneed_l1) begin
              // WRITE that lands ENTIRELY in line L+1 (low bytes all unstrobed) → begin
              // at phase 1 directly, so line L is never needlessly allocated + marked
              // dirty for a store that did not modify it (keeps dirty == modified, and
              // avoids the spurious eviction writeback that follows).
              cur_addr <= l1b;     phase <= 1'b1;
              wbe      <= nbe1;     wwd   <= nwd1;
              mra      <= l1b[OFF_W +: IDX_W];
              state    <= S_LK0;
            end else begin
              // degenerate write with NO strobed bytes → ack, touch nothing.
              cur_addr <= u_addr;  phase <= 1'b0;
              state    <= S_WACK;
            end
          end
        end

        // ---- tag lookup ----------------------------------------------------
        S_LK0: state <= S_LK1;                   // meta_q becomes valid next cycle

        S_LK1: begin
          // latch what the later miss states need (decode is stable through them,
          // but latch to be robust + readable).
          sel_way  <= hit ? hit_way : vic_way;
          plru_lat <= dec_plru;
          wb_base  <= {vic_tag, cur_set, {OFF_W{1'b0}}};
          if (!cur_we) begin
            // READ (always a single line, WORDS words)
            if (hit) begin sw <= '0; state <= S_RHIT_WAIT; end       // data read launched (dgo)
            else     begin dw <= '0; state <= vic_dirty ? S_EV_WAIT : S_FILL; end
          end else begin
            // WRITE (write-through from L1; write-back/allocate here)
            if (hit) state <= S_WDONE;                               // store merged in-place (dwe)
            else     begin dw <= '0; state <= vic_dirty ? S_EV_WAIT : S_FILL; end
          end
        end

        // ---- read hit: capture the line, then stream ------------------------
        S_RHIT_WAIT: if (data_valid) begin line_buf <= data_out; sw <= '0; state <= S_STREAM; end

        S_STREAM: begin
          if (sw < WORDS[3:0]) sw <= sw + 4'd1;
          if (sw == WORDS[3:0]-4'd1) state <= S_IDLE;                // 8th word emitted
        end

        // ---- dirty victim: capture its line, then write it back -------------
        S_EV_WAIT: if (data_valid) begin wb_buf <= data_out; dw <= '0; state <= S_WB; end

        S_WB: if (d_ack) begin
          if (dw == WORDS[3:0]-4'd1) begin dw <= '0; state <= S_FILL; end
          else dw <= dw + 4'd1;
        end

        // ---- fill the line from DDR ----------------------------------------
        S_FILL: if (d_ack) begin
          fill_buf[dw*32 +: 32] <= d_rdata;
          if (dw == WORDS[3:0]-4'd1) begin dw <= '0; state <= S_MERGE; end
          else dw <= dw + 4'd1;
        end

        // ---- commit the filled line (writes driven combinationally) --------
        S_MERGE: state <= cur_we ? S_WDONE : S_IDLE;                 // read miss already streamed

        // ---- write transaction: second phase (line straddle) or ack --------
        S_WDONE: begin
          if (phase == 1'b0 && need_l1) begin
            phase    <= 1'b1;
            cur_addr <= p1base;
            wbe      <= be1; wwd <= wd1;
            mra      <= p1base[OFF_W +: IDX_W];
            state    <= S_LK0;
          end else state <= S_WACK;
        end

        S_WACK: state <= S_IDLE;                                     // u_ack pulsed (comb)

        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef VEN_DBG_CORE
  // ---- observability counters (opt-in) ---------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin dbg_hits <= '0; dbg_misses <= '0; dbg_wbacks <= '0; end
    else begin
      if (state == S_LK1) begin
        if (hit) dbg_hits   <= dbg_hits   + 32'd1;
        else     dbg_misses <= dbg_misses + 32'd1;
      end
      if (state == S_EV_WAIT && data_valid) dbg_wbacks <= dbg_wbacks + 32'd1;
    end
  end
`endif

`ifndef SYNTHESIS
  // ---- bound protocol checks -------------------------------------------------
  // downstream read base is always 32B-aligned on the FIRST beat (so ven_axi_master's
  // INCR8 never crosses a 4KiB page — its own ar_4k assert depends on this); after the
  // first beat (dw!=0) the walking word address is intentionally unaligned.
  d_ar_align: assert property (@(posedge clk) disable iff (!rst_n)
      (d_req && !d_we) |-> (d_addr[OFF_W-1:0] == '0) || (dw != '0));
  // downstream direction is exactly the state: a fill (S_FILL) reads, a writeback
  // (S_WB) writes, and those are the only states that assert d_req. (Replaces a former
  // vacuous form that ANDed d_we with S_FILL, where d_we is structurally 0.)
  d_no_rw: assert property (@(posedge clk) disable iff (!rst_n)
      d_req |-> (d_we == (state==S_WB)));
  // upstream ack only in the legal states.
  u_ack_legal: assert property (@(posedge clk) disable iff (!rst_n)
      u_ack |-> (state==S_STREAM) || (state==S_FILL && !cur_we) || (state==S_WACK));
  // the data array is never read and written in the same cycle (SDP-safe).
  data_no_rw: assert property (@(posedge clk) disable iff (!rst_n) !(dgo && dwe));
  // single-outstanding: while NOT re-armed (u_req has not gone low since the last
  // accept), we never leave S_IDLE — a request held past its ack is not re-executed.
  // (Fires if the S_IDLE req_armed guard is ever removed while an upstream holds req.)
  u_single: assert property (@(posedge clk) disable iff (!rst_n)
      (state==S_IDLE && !req_armed) |=> (state==S_IDLE));
`endif

  // lint sink: cur_addr[4:0] (line-offset — reads stream the whole line, a write's
  // offset is consumed into be0/wd0 at accept) and the be0/wd0 phase-0 latches (kept
  // for clarity/debug; the active store is carried in wbe/wwd).
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, be0, wd0, cur_addr[OFF_W-1:0]};
  // verilator lint_on UNUSED

endmodule : ven_l2
